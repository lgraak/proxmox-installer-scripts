#!/bin/bash
# create-vm.sh
# Proxmox Virtual Machine Creator (no sudo user, .env loaded, VLAN support, DHCP fix)

set -e

# Load .env
if [ ! -f ".env" ]; then
  echo "Missing .env file. Please create one from env-template."
  exit 1
fi
source ".env"

LOGFILE="./create-vm.log"

function prompt_password_twice() {
  local PROMPT_TITLE=$1
  local PASSWORD1 PASSWORD2
  while true; do
    PASSWORD1=$(whiptail --passwordbox "$PROMPT_TITLE" 10 60 3>&1 1>&2 2>&3) || exit 1
    PASSWORD2=$(whiptail --passwordbox "Confirm $PROMPT_TITLE" 10 60 3>&1 1>&2 2>&3) || exit 1
    if [[ "$PASSWORD1" == "$PASSWORD2" ]]; then
      echo "$PASSWORD1"
      break
    else
      whiptail --title "Error" --msgbox "Passwords do not match. Try again." 10 60
    fi
  done
}

function select_version() {
  VERSION=$(whiptail --title "Select Ubuntu Version" --menu "Choose Ubuntu Version" 15 60 4 \
    "18.04" "Bionic" \
    "20.04" "Focal" \
    "22.04" "Jammy" \
    "24.04" "Noble" \
    3>&1 1>&2 2>&3) || exit 1
}

function select_storage() {
  STORAGE_OPTIONS=()
  while read -r STORAGE TYPE STATUS _; do
    if [[ "$STATUS" == "active" && "$TYPE" == "lvmthin" ]]; then
      STORAGE_OPTIONS+=("$STORAGE" "")
    fi
  done < <(pvesm status | awk '{print $1, $2, $3}')
  
  STORAGE_OPTIONS+=("$DEFAULT_SHARED_STORAGE" "")
  STORAGE=$(whiptail --title "Select Storage" --menu "Choose storage for disk" 20 60 10 "${STORAGE_OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 1
}

function network_settings() {
  NET_MODE=$(whiptail --title "Network Setup" --menu "Choose network setup" 10 60 2 \
    "DHCP" "Automatic IP assignment" \
    "Static" "Manually configure IP" \
    3>&1 1>&2 2>&3) || exit 1

  VLANID=$(whiptail --inputbox "Enter VLAN ID (or leave blank for no VLAN):" 10 60 3>&1 1>&2 2>&3) || exit 1

  if [[ "$NET_MODE" == "Static" ]]; then
    while true; do
      IPADDR=$(whiptail --inputbox "Enter static IP (CIDR format, e.g., 192.168.1.100/24):" 10 60 3>&1 1>&2 2>&3) || exit 1
      if [[ "$IPADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        break
      else
        whiptail --title "Invalid Format" --msgbox "IP must include subnet, like 192.168.1.100/24." 10 60
      fi
    done
    GATEWAY=$(whiptail --inputbox "Enter Gateway IP:" 10 60 "192.168.1.1" 3>&1 1>&2 2>&3) || exit 1
    DNS=$(whiptail --inputbox "Enter DNS Server(s) (comma-separated):" 10 60 "$DEFAULT_DNS" 3>&1 1>&2 2>&3) || exit 1
  fi
}

function general_settings() {
  NODE=$(whiptail --inputbox "Enter Proxmox Node Name:" 10 60 "$(hostname)" 3>&1 1>&2 2>&3) || exit 1
  select_storage
  ID=$(whiptail --inputbox "Enter VMID (unique number):" 10 60 100 3>&1 1>&2 2>&3) || exit 1
  HOSTNAME=$(whiptail --inputbox "Enter Hostname:" 10 60 "testvm" 3>&1 1>&2 2>&3) || exit 1
  CPU=$(whiptail --inputbox "Enter number of CPU cores:" 10 60 2 3>&1 1>&2 2>&3) || exit 1
  RAM=$(whiptail --inputbox "Enter RAM (MB):" 10 60 2048 3>&1 1>&2 2>&3) || exit 1
  DISK=$(whiptail --inputbox "Enter disk size (GB):" 10 60 10 3>&1 1>&2 2>&3) || exit 1
  SSHKEY=$(whiptail --inputbox "Paste SSH Public Key for root user:" 12 80 3>&1 1>&2 2>&3) || exit 1
  ROOT_PASS=$(prompt_password_twice "root user password")
}

function create_vm() {
  mkdir -p /mnt/pve/$DEFAULT_TEMPLATE_STORAGE/template/qcow2/

  if [[ "$VERSION" == "22.04" ]]; then
    CLOUD_IMAGE="jammy-server-cloudimg-amd64.img"
  elif [[ "$VERSION" == "24.04" ]]; then
    CLOUD_IMAGE="noble-server-cloudimg-amd64.img"
  else
    CLOUD_IMAGE="ubuntu-${VERSION}-cloudimg-amd64.img"
  fi

  IMG_FILE="/mnt/pve/$DEFAULT_TEMPLATE_STORAGE/template/qcow2/$CLOUD_IMAGE"

  if [ ! -f "$IMG_FILE" ]; then
    echo "Downloading cloud image..." | tee -a "$LOGFILE"
    wget -O "$IMG_FILE" "https://cloud-images.ubuntu.com/releases/${VERSION}/release/${CLOUD_IMAGE}" 2>&1 | tee -a "$LOGFILE"
  fi

  if [[ -n "$VLANID" ]]; then
    NET_CONFIG="virtio,bridge=vmbr0,tag=$VLANID"
  else
    NET_CONFIG="virtio,bridge=vmbr0"
  fi

  qm create "$ID" --name "$HOSTNAME" --memory "$RAM" --cores "$CPU" --net0 "$NET_CONFIG" --ostype l26 \
    --machine q35 --bios ovmf --scsihw virtio-scsi-pci \
    --ide2 "$STORAGE":cloudinit \
    --scsi0 "$STORAGE":0,import-from="$IMG_FILE" 2>&1 | tee -a "$LOGFILE"

  qm set "$ID" --sshkeys <(echo "$SSHKEY") 2>&1 | tee -a "$LOGFILE"
  qm set "$ID" --ciuser root --cipassword "$ROOT_PASS" 2>&1 | tee -a "$LOGFILE"

  if [[ "$NET_MODE" == "Static" ]]; then
    qm set "$ID" --ipconfig0 "ip=$IPADDR,gw=$GATEWAY" 2>&1 | tee -a "$LOGFILE"
    qm set "$ID" --nameserver "$DNS" 2>&1 | tee -a "$LOGFILE"
  else
    qm set "$ID" --ipconfig0 "ip=dhcp" 2>&1 | tee -a "$LOGFILE"
  fi

  qm set "$ID" --efidisk0 "$STORAGE":0,efitype=4m,pre-enrolled-keys=1 2>&1 | tee -a "$LOGFILE"
  qm resize "$ID" scsi0 "${DISK}G" 2>&1 | tee -a "$LOGFILE"
  qm start "$ID" 2>&1 | tee -a "$LOGFILE"
}

function build_complete() {
  whiptail --title "Success" --msgbox "🎉 VM created successfully!" 10 60
}

# --- Main Execution ---
select_version
general_settings
network_settings
create_vm
build_complete
