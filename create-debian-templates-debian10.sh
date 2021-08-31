#!/bin/sh

set -e

# Inspired by https://pve.proxmox.com/wiki/Cloud-Init_Support

PROXY=""
QCOW_URL="https://cloud.debian.org/images/cloud/buster/20210329-591/debian-10-genericcloud-amd64-20210329-591.qcow2"
DEST_QCOW_ORIG="debian-10.qcow2"
DEST_QCOW="debian-10-xfs.qcow2"
#PROXMOX_STORAGE="proxmox-nfs-syno"
PROXMOX_STORAGE="local-zfs"
VM_ID=9000
VM_NAME="debian-10-template"
VM_BRIDGE=vmbr2922

http_proxy=${PROXY} \
https_proxy=${PROXY} \
wget -c "${QCOW_URL}" -O "${DEST_QCOW_ORIG}"

# Convert to XFS filesystem
PROXY=${PROXY} ./convert-qcow-image-from-ext4-to-xfs.sh "${DEST_QCOW_ORIG}"

qm create ${VM_ID} --name "${VM_NAME}" --memory 1024 --net0 virtio,bridge=${VM_BRIDGE}

# import the downloaded disk to local storage
qm importdisk ${VM_ID} "${DEST_QCOW}" ${PROXMOX_STORAGE}

# finally attach the new disk to the VM as scsi drive
qm set ${VM_ID} --scsihw virtio-scsi-pci --scsi0 ${PROXMOX_STORAGE}:vm-${VM_ID}-disk-0,cache=writeback,discard=on
#qm set ${VM_ID} --scsihw virtio-scsi-pci --scsi0 ${PROXMOX_STORAGE}:${VM_ID}/vm-${VM_ID}-disk-0.raw,cache=writeback,discard=on

# The next step is to configure a CDROM drive which will be used to pass the Cloud-Init data to the VM.
qm set ${VM_ID} --ide2 ${PROXMOX_STORAGE}:cloudinit

# To be able to boot directly from the Cloud-Init image, set the bootdisk parameter to scsi0, and restrict BIOS to boot from disk only. This will speed up booting, because VM BIOS skips the testing for a bootable CDROM.
qm set ${VM_ID} --boot c --bootdisk scsi0

# Enable SPICE display
qm set ${VM_ID} --vga qxl

# Disable memory balooning and set CPU to host
qm set ${VM_ID} --balloon 0 --cpu host

# Enable guest agent and start on boot
qm set ${VM_ID} --agent 1 --onboot 1

# In a last step, it is helpful to convert the VM into a template. From this template you can then quickly create linked clones. The deployment from VM templates is much faster than creating a full clone (copy).
qm template ${VM_ID}

echo "/usr/bin/chattr error is harmless, seems to be related to NFS"
