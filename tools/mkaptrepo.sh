#!/bin/bash -e
# Build an apt repository tree from a directory of .deb files.
#
# Usage: tools/mkaptrepo.sh <debs-dir> <output-dir> [suite ...]
#
# Layout produced:
#   <output-dir>/pool/main/<p>/<pkg>_<ver>_<arch>.deb
#   <output-dir>/dists/<suite>/Release
#   <output-dir>/dists/<suite>/InRelease          (if SIGN_KEY is set)
#   <output-dir>/dists/<suite>/Release.gpg        (if SIGN_KEY is set)
#   <output-dir>/dists/<suite>/main/binary-<arch>/Packages{,.gz}
#
# Environment:
#   SIGN_KEY   gpg key id/fingerprint to sign Release (InRelease + Release.gpg).
#              Without it the repo is unsigned (fine for testing; apt clients
#              need trusted=yes or a manual key).
#   ORIGIN     Release Origin field (default: CtxOS)
#   LABEL      Release Label field (default: $ORIGIN)
#   COMPONENT  component name (default: main)

set -o pipefail

ORIGIN="${ORIGIN:-CtxOS}"
LABEL="${LABEL:-$ORIGIN}"
COMPONENT="${COMPONENT:-main}"

DEBS_DIR="$1"
OUT_DIR="$2"
shift 2 || true
SUITES=("$@")
if [ ${#SUITES[@]} -eq 0 ]; then
	SUITES=(lory)
fi

if [ -z "${DEBS_DIR}" ] || [ -z "${OUT_DIR}" ] || [ ! -d "${DEBS_DIR}" ]; then
	echo "usage: $0 <debs-dir> <output-dir> [suite ...]" >&2
	exit 1
fi

OUT_DIR="$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)"
DEBS_DIR="$(cd "${DEBS_DIR}" && pwd)"

# collect .deb files, reject duplicates by pool file name
DEBS=()
declare -A SEEN=()
while IFS= read -r -d '' deb; do
	arch="$(dpkg-deb -f "${deb}" Architecture)"
	pkg="$(dpkg-deb -f "${deb}" Package)"
	ver="$(dpkg-deb -f "${deb}" Version)"
	fname="${pkg}_${ver}_${arch}.deb"
	if [ -n "${SEEN[$fname]}" ]; then
		echo "error: duplicate package file name ${fname}:" >&2
		echo "  ${SEEN[$fname]}" >&2
		echo "  ${deb}" >&2
		exit 1
	fi
	SEEN[$fname]="${deb}"
	DEBS+=("${deb}")
done < <(find "${DEBS_DIR}" -name '*.deb' -type f -print0)

if [ ${#DEBS[@]} -eq 0 ]; then
	echo "error: no .deb files found under ${DEBS_DIR}" >&2
	exit 1
fi

# architectures present ("all" packages ride along in every arch index)
ARCHS_TMP="$(mktemp)"
for deb in "${DEBS[@]}"; do
	dpkg-deb -f "${deb}" Architecture
done | sort -u > "${ARCHS_TMP}"
mapfile -t ARCHS < <(grep -v '^all$' "${ARCHS_TMP}" || true)
rm -f "${ARCHS_TMP}"
if [ ${#ARCHS[@]} -eq 0 ]; then
	echo "error: only Architecture: all packages found; need at least one real architecture" >&2
	exit 1
fi

# stage pool
rm -rf "${OUT_DIR}/pool"
POOL="${OUT_DIR}/pool/${COMPONENT}"
mkdir -p "${POOL}"
declare -A POOL_PATH=()
for deb in "${DEBS[@]}"; do
	pkg="$(dpkg-deb -f "${deb}" Package)"
	mkdir -p "${POOL}/${pkg:0:1}"
	[ -e "${POOL}/${pkg:0:1}/$(basename "${deb}")" ] || cp "${deb}" "${POOL}/${pkg:0:1}/"
	POOL_PATH[$deb]="${COMPONENT}/${pkg:0:1}/$(basename "${deb}")"
done

# generate Packages per suite and arch
for SUITE in "${SUITES[@]}"; do
	for ARCH in "${ARCHS[@]}"; do
		DIR="${OUT_DIR}/dists/${SUITE}/${COMPONENT}/binary-${ARCH}"
		mkdir -p "${DIR}"
		PKGLIST="${DIR}/Packages"
		: > "${PKGLIST}"
		for deb in "${DEBS[@]}"; do
			deb_arch="$(dpkg-deb -f "${deb}" Architecture)"
			if [ "${deb_arch}" != "${ARCH}" ] && [ "${deb_arch}" != "all" ]; then
				continue
			fi
			rel_file="pool/${POOL_PATH[$deb]}"
			abs_file="${OUT_DIR}/${rel_file}"
			{
				dpkg-deb -f "${deb}"
				echo "Filename: ${rel_file}"
				echo "Size: $(stat -c %s "${abs_file}")"
				echo "MD5sum: $(md5sum "${abs_file}" | cut -d' ' -f1)"
				echo "SHA256: $(sha256sum "${abs_file}" | cut -d' ' -f1)"
				echo
			} >> "${PKGLIST}"
		done
		if [ ! -s "${PKGLIST}" ]; then
			rm -rf "${OUT_DIR}/dists/${SUITE}/${COMPONENT}"
			continue
		fi
		gzip -9 -n -c "${PKGLIST}" > "${PKGLIST}.gz"
		echo "built ${PKGLIST#"${OUT_DIR}"/} ($(grep -c '^Package:' "${PKGLIST}") packages)"
	done

	RELEASE="${OUT_DIR}/dists/${SUITE}/Release"
	{
		echo "Origin: ${ORIGIN}"
		echo "Label: ${LABEL}"
		echo "Suite: ${SUITE}"
		echo "Codename: ${SUITE}"
		echo "Date: $(date -Ru)"
		echo "Architectures: ${ARCHS[*]}"
		echo "Components: ${COMPONENT}"
		echo "Description: ${ORIGIN} ${SUITE} repository"
		echo "MD5Sum:"
		while IFS= read -r f; do
			rel="${f#"${OUT_DIR}/dists/${SUITE}/"}"
			printf ' %s %s %s\n' "$(md5sum "${f}" | cut -d' ' -f1)" "$(stat -c %s "${f}")" "${rel}"
		done < <(find "${OUT_DIR}/dists/${SUITE}" -type f ! -name 'Release' ! -name 'Release.gpg' ! -name 'InRelease' | sort)
		echo "SHA256:"
		while IFS= read -r f; do
			rel="${f#"${OUT_DIR}/dists/${SUITE}/"}"
			printf ' %s %s %s\n' "$(sha256sum "${f}" | cut -d' ' -f1)" "$(stat -c %s "${f}")" "${rel}"
		done < <(find "${OUT_DIR}/dists/${SUITE}" -type f ! -name 'Release' ! -name 'Release.gpg' ! -name 'InRelease' | sort)
	} > "${RELEASE}"

	if [ -n "${SIGN_KEY}" ]; then
		rm -f "${RELEASE}.gpg" "${OUT_DIR}/dists/${SUITE}/InRelease"
		gpg --batch --yes --local-user "${SIGN_KEY}" --digest-algo SHA256 \
			--clearsign -o "${OUT_DIR}/dists/${SUITE}/InRelease" "${RELEASE}"
		gpg --batch --yes --local-user "${SIGN_KEY}" --digest-algo SHA256 \
			--armor --detach-sign -o "${RELEASE}.gpg" "${RELEASE}"
		echo "signed dists/${SUITE} with ${SIGN_KEY}"
		# public half at repo root: images fetch this as
		# <mirror>/ctxos-archive-keyring.gpg for signed-by= trust
		gpg --export "${SIGN_KEY}" > "${OUT_DIR}/ctxos-archive-keyring.gpg"
	else
		echo "warning: SIGN_KEY not set; dists/${SUITE} is unsigned" >&2
	fi
done

echo "repository ready at ${OUT_DIR}"
