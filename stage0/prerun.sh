#!/bin/bash -e

if [ "$RELEASE" != "echo" ]; then
	echo "WARNING: RELEASE does not match the intended option for this branch."
	echo "         Please check the relevant README.md section."
fi

if [ "${USE_QCOW2}" != "1" ] && [ -d "${ROOTFS_DIR}" ] && [ ! -f "${STAGE_WORK_DIR}/bootstrap-complete" ]; then
	echo "Removing incomplete rootfs ${ROOTFS_DIR} left by a previous run"
	unmount "${ROOTFS_DIR}"
	rm -rf "${ROOTFS_DIR}"
fi

if [ ! -d "${ROOTFS_DIR}" ] || [ "${USE_QCOW2}" = "1" ]; then
	mkdir -p "${STAGE_WORK_DIR}"
	# debootstrap tests that it can create and use device nodes on the
	# target, which fails when the filesystem is mounted nodev (common
	# for container volumes and CI filesystems)
	mount -o remount,dev "$(findmnt -no TARGET -T "${STAGE_WORK_DIR}")" 2>/dev/null || true
	# debootstrap only ships suite scripts for known Debian releases;
	# Parrot codenames such as echo use the generic sid script
	if [ ! -e "/usr/share/debootstrap/scripts/${RELEASE}" ]; then
		ln -sf sid "/usr/share/debootstrap/scripts/${RELEASE}"
	fi
	bootstrap ${RELEASE} "${ROOTFS_DIR}" https://deb.parrot.sh/parrot
fi
