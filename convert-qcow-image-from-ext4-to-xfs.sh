#!/bin/bash

# Inverted version of
# https://raw.githubusercontent.com/akram/qcow-utils/master/convert-qcow-image-from-xfs-to-ext4.sh

set -euo pipefail

readonly ext4_device=/dev/nbd0
readonly xfs_device=/dev/nbd1

function log {
    tput bold
    printf "$1\n"
    tput sgr0
}

if [[ $# != 1 ]]; then
    printf "Usage: $(basename $0) <debian-10.qcow2>\n" >&2
    exit 1
fi

readonly ext4_image="$1"
readonly xfs_image="${ext4_image%.qcow2}-xfs.qcow2"
readonly xfs_image_vmdk="${xfs_image%.qcow2}.vmdk"
readonly wip_xfs_image="$(dirname $xfs_image)/WIP-$(basename $xfs_image)"

log "Checking prerequisites..."

for cmd in qemu-img qemu-nbd jq parted mkfs.xfs rsync; do
  if ! command -v $cmd &> /dev/null; then
    printf -- "please install ${cmd}.\n" >&2
    exit 1
  fi
done

if [[ ! -f "$ext4_image" ]]; then
    printf -- "$ext4_image file doesn’t exist.\n" >&2
    exit 1
fi

if qemu-img info --output=json "$ext4_image" | jq -e '.format != "qcow2"'; then
    printf -- "$ext4_image file isn’t a QCow2 image.\n" >&2
    exit 1
fi

log "Loading nbd module..."
modprobe nbd max_part=63

log "Creating mount points..."
readonly ext4_mount=$(mktemp -d)
readonly  xfs_mount=$(mktemp -d)
readonly efi_orig_mount=${ext4_mount}/boot/efi/
readonly efi_dest_mount=${xfs_mount}/boot/efi/

function detach_both {
    umount -R "$efi_orig_mount" "$efi_dest_mount" "$ext4_mount" "$xfs_mount"
    qemu-nbd -d "$ext4_device"
    qemu-nbd -d "$xfs_device"
}

function cleanup {
    log "Cleanup..."
    set +e
    detach_both
    rmdir "$ext4_mount" "$xfs_mount"
    rm -f "$wip_xfs_image"
    set -e
}
trap cleanup EXIT

partition_id=p1
efi_partition_id=p15
ext4_partition=$ext4_device$partition_id
xfs_partition=$xfs_device$partition_id
efi_orig_partition=$ext4_device$efi_partition_id
efi_dest_partition=$xfs_device$efi_partition_id

image_size=$(qemu-img info --output=json "$ext4_image" | jq '."virtual-size"')

log "Mounting the ext4-formated partition..."
qemu-nbd -r -c "$ext4_device" "$ext4_image"
while [[ ! -e "$ext4_partition" ]]; do
    sleep .1
done
mount -o ro "$ext4_partition" "$ext4_mount"

log "Creating the xfs-formated disk..."
qemu-img create -f qcow2 "$wip_xfs_image" "$image_size"
qemu-nbd --discard=unmap -c "$xfs_device" "$wip_xfs_image"

log "Duplicating partition table from old disk to new one"
sfdisk -d "$ext4_device" | sfdisk "$xfs_device"
#sgdisk "$ext4_device" -R "$xfs_device"
blockdev --flushbufs $xfs_device

# I have no idea why this is not working, looks like a bug to me
# partition is correctly created and working but has no UUID so it fails
# to mount on boot
#
#log "Raw copy of other partitions (e.g: EFI or grub boot partitions)"
#for other_part in `sfdisk -d "$ext4_device" | grep ^/dev | awk '{ print $1 }'`; do
#  if [ "${other_part}" = "$ext4_partition" ]; then
#    continue
#  fi
#  new_other_part=${other_part/$ext4_device/$xfs_device}
#  log "Duplicating part ${other_part} to /dev/${new_other_part}"
#  dd if=$other_part of=$new_other_part oflag=sync
#  blockdev --flushbufs $xfs_device
#done

log "Formating the xfs-formated disk..."
mkfs.xfs -L root "$xfs_partition"

log "Mounting the xfs-formated partition..."
mount "$xfs_partition" "$xfs_mount"

log "Copying source files to destination images..."
rsync -a "$ext4_mount"/ "$xfs_mount"/

log "Recreating EFI partition..."
mount -o ro "$efi_orig_partition" "$efi_orig_mount"
mkfs.fat -F32 -n EFI $xfs_device$efi_partition_id
mount "$efi_dest_partition" "$efi_dest_mount"
rsync -rv "$efi_orig_mount"/ "$efi_dest_mount"/

log "Patching files where partition UUID are used"
readonly ext4_uuid=$(blkid -o value -s UUID "$ext4_partition")
readonly  xfs_uuid=$(blkid -o value -s UUID "$xfs_partition")
readonly efi_orig_uuid=$(blkid -o value -s UUID "$efi_orig_partition")
readonly efi_dest_uuid=$(blkid -o value -s UUID "$efi_dest_partition")

set -x
for file in /etc/fstab \
            /boot/grub/grub.cfg; do
	sed -i "s/$efi_orig_uuid/$efi_dest_uuid/g" "$xfs_mount/$file"
	sed -i "s/$ext4_uuid/$xfs_uuid/g" "$xfs_mount/$file"
        # For grub
	sed -i "s/insmod ext2/insmod xfs/g" "$xfs_mount/$file"
done
set +x
sed -i 's!ext4!xfs!' "$xfs_mount/etc/fstab"
sed -i 's!,errors=remount-ro!!' "$xfs_mount/etc/fstab"
sed -i 's!,x-systemd.growfs!!' "$xfs_mount/etc/fstab"
#sed -i 's!,discard!!' "$xfs_mount/etc/fstab"
cat "$xfs_mount/etc/fstab"

log "Patching grub.cfg to remove serial stuff that makes grub prompt hidden on real display"
sed -i '/^GRUB_TERMINAL=/d' "$xfs_mount/etc/default/grub"
sed -i '/^GRUB_SERIAL_COMMAND=/d' "$xfs_mount/etc/default/grub"
sed -i '/^GRUB_CMDLINE_LINUX=/d' "$xfs_mount/etc/default/grub"
echo 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"' >> "$xfs_mount/etc/default/grub"
echo "# Also check /etc/default/grub.d/ if behavior looks odd to you" >> "$xfs_mount/etc/default/grub"
cat "$xfs_mount/etc/default/grub"

# Enable root account and SSH
log "Enable root account with root password and allow SSH"
chroot "$xfs_mount" /bin/sh -c 'echo "root:root" | chpasswd'
sed -i 's!^#\?PermitRootLogin .*!PermitRootLogin yes!' "$xfs_mount/etc/ssh/sshd_config"
sed -i 's!^\(PasswordAuthentication\s.*\)!#\1!' "$xfs_mount/etc/ssh/sshd_config"

log "Installing GRUB"
for m in /dev /proc /sys /dev/pts; do
    mount --bind "$m" "$xfs_mount$m"
done
# This file override grub timeout from /etc/default
chroot "$xfs_mount" /usr/sbin/grub-install --recheck --target=i386-pc "$xfs_device"
rm -f "$xfs_mount/etc/default/grub.d/15_timeout.cfg"
chroot "$xfs_mount" update-grub
# For some reason it won't use UUID on Debian 10
sed -i "s/root=\/dev\/[a-z0-9]\+/root=UUID=${xfs_uuid}/g" "$xfs_mount/boot/grub/grub.cfg"
cat "$xfs_mount/boot/grub/grub.cfg"

log "Enable Internet access inside chroot by mimicing host config"
mv "$xfs_mount/etc/resolv.conf" "$xfs_mount/etc/resolv.conf.orig"
cp -v /etc/resolv.conf "$xfs_mount/etc/resolv.conf"

log "Upgrade system and install xfs utilities, grub efi, puppet, vmware tools..."
http_proxy=${PROXY} https_proxy=${PROXY} LANG=C chroot "$xfs_mount" apt update
http_proxy=${PROXY} https_proxy=${PROXY} LANG=C chroot "$xfs_mount" apt full-upgrade --yes
http_proxy=${PROXY} https_proxy=${PROXY} LANG=C chroot "$xfs_mount" apt install --no-install-recommends --yes debconf-utils xfsprogs grub-efi-amd64-signed grub-efi-amd64-bin dirmngr lsb-release puppet open-vm-tools qemu-guest-agent
http_proxy=${PROXY} https_proxy=${PROXY} LANG=C chroot "$xfs_mount" apt purge --yes grub-cloud-amd64 unattended-upgrades --auto-remove
# Install fr-CH keymap

log "Set machine keymap to fr_CH"
# Inspired from https://serverfault.com/a/1050653
DEBIAN_FRONTEND=noninteractive http_proxy=${PROXY} https_proxy=${PROXY} LANG=C chroot "$xfs_mount" apt install --yes keyboard-configuration console-setup
cat << EOF > "${xfs_mount}/etc/default/keyboard"
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="ch"
XKBVARIANT="fr"
XKBOPTIONS=""

BACKSPACE="guess"
EOF
DEBIAN_FRONTEND=noninteractive LANG=C chroot "$xfs_mount" dpkg-reconfigure keyboard-configuration

mv -v "$xfs_mount/etc/resolv.conf.orig" "$xfs_mount/etc/resolv.conf"
LANG=C chroot "$xfs_mount" apt clean
LANG=C chroot "$xfs_mount" /bin/sh -c 'echo "debconf	debconf/priority	select	medium" | debconf-set-selections'
DEBIAN_FRONTEND=noninteractive LANG=C chroot "$xfs_mount" dpkg-reconfigure debconf
rm -rf "$xfs_mount/var/lib/apt/lists/"*
# This file generate useless dhcp config at boot time
rm -f "$xfs_mount/etc/udev/rules.d/75-cloud-ifupdown.rules"
# If proxy env is set, also set it in APT config so cloud-init works correctly
if [ -n "${PROXY}" ]; then
  log "Setting APT proxy to ${PROXY}"
  echo "Acquire::http::proxy \"${PROXY}/\";" >> "$xfs_mount/etc/apt/apt.conf.d/01proxy"
  echo "Acquire::https::proxy \"${PROXY}/\";" >> "$xfs_mount/etc/apt/apt.conf.d/01proxy"
fi

log "Uninstall cloud-initramfs-growroot that triggers kernel panic when disk is extended"
LANG=C chroot "$xfs_mount" apt purge --yes cloud-initramfs-growroot --auto-remove

log "Call fstrim to reclaim unused disk space"
fstrim -v "$xfs_mount"

# Umount so XFS FS is unmounted cleanly before calling qemu-img convert again
detach_both

log "Converting again to shrink zero blocks"
qemu-img convert -O qcow2 -c "$wip_xfs_image" "$xfs_image"
qemu-img convert -O vmdk "$wip_xfs_image" "$xfs_image_vmdk"

log "Finished !"
