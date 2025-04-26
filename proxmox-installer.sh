#!/bin/bash

# Proxmox Ubuntu VM Cloud-Init Installer Script
# This script sets up a new Ubuntu VM on Proxmox with cloud-init configuration.
# It dynamically selects storage (LVM-Thin only, plus optional proxmox-vmstore) and downloads the specified Ubuntu cloud image.
# Default DNS servers and other network parameters are preset as requested.

set -e  # Exit immediately on any error

# Default configuration values
VM_NAME="Ubuntu-VM"          # Default VM name
VM_MEMORY="2048"             # Default RAM in MB
VM_CORES="2"                 # Default number of vCPUs
DEFAULT_DNS="192.168.1.10,192.168.20.10,192.168.20.20"  # Default DNS servers
DEFAULT_GATEWAY="192.168.1.1"                          # Default gateway
DEFAULT_IP=""  # Default IP (empty means use DHCP by default)

# Prompt user for basic VM parameters
VM_NAME=$(whiptail --inputbox "Enter VM name:" 8 60 "$VM_NAME" 3>&1 1>&2 2>&3) || exit 1
VM_MEMORY=$(whiptail --inputbox "Enter RAM in MB:" 8 60 "$VM_MEMORY" 3>&1 1>&2 2>&3) || exit 1
VM_CORES=$(whiptail --inputbox "Enter number of CPU cores:" 8 60 "$VM_CORES" 3>&1 1>&2 2>&3) || exit 1

# Network configuration: DHCP or static
if whiptail --yesno "Use DHCP for VM networking? \n(Select <No> for static IP configuration)" 8 60; then
    VM_IP=""       # DHCP will be used
    VM_GATEWAY=""  # not needed for DHCP
    VM_DNS="$DEFAULT_DNS"
else
    VM_IP=$(whiptail --inputbox "Enter static IP (CIDR format, e.g. 192.168.1.100/24):" 8 60 "$DEFAULT_IP" 3>&1 1>&2 2>&3) || exit 1
    VM_GATEWAY=$(whiptail --inputbox "Enter default gateway IP:" 8 60 "$DEFAULT_GATEWAY" 3>&1 1>&2 2>&3) || exit 1
    VM_DNS=$(whiptail --inputbox "Enter DNS server(s) (comma-separated):" 8 60 "$DEFAULT_DNS" 3>&1 1>&2 2>&3) || exit 1
fi

# Ubuntu version selection for the cloud image
UBUNTU_VERSION=$(whiptail --inputbox "Enter Ubuntu version to install (e.g., 20.04, 22.04, 24.04):" 8 60 "22.04" 3>&1 1>&2 2>&3) || exit 1
# Normalize version format (strip patch number if any, e.g. 20.04.6 -> 20.04)
if [[ $UBUNTU_VERSION =~ ^[0-9]{2}\.[0-9]{2}\. ]]; then
    UBUNTU_VERSION="${UBUNTU_VERSION%%.*.*}"
fi

# Build storage options list (only LVM-Thin storages, plus always include proxmox-vmstore)
STORAGE_MENU=()
MSG_MAX_LENGTH=0
found_vmstore=false
# Parse `pvesm status` output, skipping header
while read -r line; do
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    # Only consider LVM-Thin storage entries
    if [[ $(echo "$line" | awk '{print $2}') != "lvmthin" ]]; then
        continue
    fi
    # Compute free space in human-readable form
    FREE=$(echo "$line" | numfmt --field 4-6 --from=K --to=iec --format "%.2f" | awk '{printf "%9sB", $6}')
    ITEM="  Type: $TYPE Free: $FREE "
    # Track longest line for whiptail width
    if (( ${#ITEM} + 2 > MSG_MAX_LENGTH )); then
        MSG_MAX_LENGTH=$(( ${#ITEM} + 2 ))
    fi
    STORAGE_MENU+=( "$TAG" "$ITEM" "OFF" )
    if [[ "$TAG" == "proxmox-vmstore" ]]; then
        found_vmstore=true
    fi
done < <(pvesm status | awk 'NR>1')

# Ensure 'proxmox-vmstore' is in the list at least once
if [ "$found_vmstore" = false ]; then
    TAG="proxmox-vmstore"
    TYPE=$(printf "%-10s" "lvmthin")
    # Determine free space if possible for proxmox-vmstore
    FREE_DISPLAY="Unknown"
    # If storage is defined in PVE (but was filtered due to type), get its available space
    if pvesm status | awk 'NR>1 {print $1,$2,$6}' | grep -qw "$TAG"; then
        FREE_VAL=$(pvesm status | awk -v id="$TAG" 'NR>1 && $1 == id {print $6}')
        if [[ "$FREE_VAL" =~ ^[0-9]+$ ]]; then
            FREE_DISPLAY=$(numfmt --to=iec --format "%.2f" "${FREE_VAL}K")
        fi
    else
        # If a volume group named 'proxmox-vmstore' exists, use its free space as hint
        if vgs "$TAG" &>/dev/null; then
            VG_FREE=$(vgs "$TAG" -o vg_free --noheadings --units G | xargs)
            # Format e.g. "50.00g" to "50.00G"
            if [[ -n "$VG_FREE" ]]; then
                FREE_DISPLAY="$(echo "$VG_FREE" | sed 's/[[:alpha:]]$//')G"
            fi
        fi
    fi
    # Format the free space field for display
    if [[ "$FREE_DISPLAY" =~ ^[0-9]+\.[0-9]+ ]]; then
        FREE=$(printf "%9sB" "$FREE_DISPLAY")
    else
        FREE=$(printf "%9s" "$FREE_DISPLAY")
    fi
    ITEM="  Type: $TYPE Free: $FREE "
    if (( ${#ITEM} + 2 > MSG_MAX_LENGTH )); then
        MSG_MAX_LENGTH=$(( ${#ITEM} + 2 ))
    fi
    STORAGE_MENU+=( "$TAG" "$ITEM" "OFF" )
fi

# (Safety filter) Remove any non-lvmthin types from the menu, if present
FILTERED_MENU=()
for ((i=0; i<${#STORAGE_MENU[@]}; i+=3)); do
    entry="${STORAGE_MENU[i+1]}"
    stor_type=$(grep -oP 'Type:\s+\K\w+' <<< "$entry")
    if [[ "$stor_type" != "lvmthin" ]]; then
        continue  # skip entries that are not lvmthin (should not happen due to filtering above)
    fi
    FILTERED_MENU+=( "${STORAGE_MENU[i]}" "${STORAGE_MENU[i+1]}" "OFF" )
done
STORAGE_MENU=( "${FILTERED_MENU[@]}" )
OPTION_COUNT=$(( ${#STORAGE_MENU[@]} / 3 ))

# Prompt user to choose storage from the built list
if (( OPTION_COUNT == 0 )); then
    whiptail --msgbox "Error: No LVM-Thin storage available. Please create an LVM-Thin storage before proceeding." 8 60
    exit 1
elif (( OPTION_COUNT == 1 )); then
    STORAGE="${STORAGE_MENU[0]}"
else
    STORAGE=$(whiptail --backtitle "Proxmox VE Storage Selection" \
        --title "Storage Pools" --radiolist "Choose a storage pool for the VM disk:" \
        16 $(( MSG_MAX_LENGTH + 23 )) $OPTION_COUNT \
        "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
fi

# Confirm the chosen storage
echo "Selected storage: $STORAGE"

# Get next available VM ID from Proxmox
VMID=$(pvesh get /cluster/nextid)
echo "Assigned VM ID: $VMID"

# Determine the storage type (dir, lvmthin, etc.) for disk format decisions
STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
DISK_FORMAT="qcow2"
DISK_EXT=".qcow2"
if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
    DISK_FORMAT="raw"
    DISK_EXT=""  # raw volumes on LVM-Thin storage have no file extension
fi

# Download the Ubuntu cloud image for the selected version
IMG_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/${IMG_NAME}"
echo "Downloading Ubuntu cloud image: $IMG_URL"
if ! wget -q -O "$IMG_NAME" "$IMG_URL"; then
    echo "Error: Failed to download $IMG_NAME. Please verify the Ubuntu version and network connectivity."
    exit 1
fi

# Create a new VM in Proxmox
qm create "$VMID" -name "$VM_NAME" -memory "$VM_MEMORY" -cores "$VM_CORES" -net0 virtio,bridge=vmbr0

# Import the downloaded disk into the selected storage
qm importdisk "$VMID" "$IMG_NAME" "$STORAGE" --format "$DISK_FORMAT"

# Attach the imported disk as the primary drive (SCSI0)
if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
    # On LVM-Thin, the disk is stored as a raw volume (no extension)
    qm set "$VMID" -scsihw virtio-scsi-pci -scsi0 "${STORAGE}:vm-${VMID}-disk-0"
else
    qm set "$VMID" -scsihw virtio-scsi-pci -scsi0 "${STORAGE}:vm-${VMID}-disk-0${DISK_EXT}"
fi

# Set boot options and add a cloud-init drive
qm set "$VMID" -boot order=scsi0 -serial0 socket -vga serial0
qm set "$VMID" -ide2 "${STORAGE}:cloudinit"

# Cloud-Init user configuration
CI_USER=$(whiptail --inputbox "Enter a username for the VM:" 8 60 "ubuntu" 3>&1 1>&2 2>&3) || exit 1
CI_PASSWORD=$(whiptail --passwordbox "Enter password for user '$CI_USER' (leave blank to disable password login):" 8 60 3>&1 1>&2 2>&3)

if [[ -n "$CI_PASSWORD" ]]; then
    qm set "$VMID" -ciuser "$CI_USER" -cipassword "$CI_PASSWORD"
else
    qm set "$VMID" -ciuser "$CI_USER"
fi

# Apply network settings via cloud-init (IP config and DNS)
if [[ -n "$VM_IP" ]]; then
    # Static networking
    qm set "$VMID" -ipconfig0 ip="$VM_IP",gw="$VM_GATEWAY"
    qm set "$VMID" -nameserver "$VM_DNS"
else
    # DHCP networking (still set DNS servers explicitly in case DHCP is not providing the desired ones)
    qm set "$VMID" -nameserver "$VM_DNS"
fi

# Start the VM
echo "Starting VM ID $VMID ..."
qm start "$VMID"

echo "Proxmox VM $VM_NAME (ID $VMID) has been created on storage '$STORAGE'."
echo "The VM is powering on and will use cloud-init for initial setup. You can access the VM via the Proxmox web console or SSH (if network is configured) once cloud-init completes."
