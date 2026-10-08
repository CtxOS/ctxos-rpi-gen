#!/bin/bash -e

install -m 644 files/sources.list "${ROOTFS_DIR}/etc/apt/"
install -m 644 files/ctx.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
install -m 644 files/raspi.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
install -m 644 files/parrot.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list.d/raspi.list"

if [ -n "$APT_PROXY" ]; then
	install -m 644 files/51cache "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
	sed "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache" -i -e "s|APT_PROXY|${APT_PROXY}|"
else
	rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
fi

on_chroot << EOF
dpkg --add-architecture armhf
# fetch the overlay repo signing key first: the keyring packages that
# trust the remaining sources live in the overlay itself
mkdir -p /usr/share/keyrings
/usr/lib/apt/apt-helper download-file https://ctxos.github.io/deb/ctxos-archive-keyring.gpg /usr/share/keyrings/ctxos-archive-keyring.gpg
chmod 644 /usr/share/keyrings/ctxos-archive-keyring.gpg
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ctx.list -o Dir::Etc::sourceparts=-
apt-get install -y ctx-archive-keyring raspberrypi-archive-keyring raspbian-archive-keyring
apt-get update
apt-get dist-upgrade -y
EOF
