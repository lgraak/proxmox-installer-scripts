#!/bin/bash
# proxmox-installer.sh (Full Version)
# Interactive Proxmox VM and LXC installer script with dynamic storage picking and cloud-init support

set -e

# Update template list
pveam update &>/dev/null

# Show success at the end
function build_complete() {
  whiptail --title "Success" --msgbox "🎉 Build Complete! Your new container or VM has been created successfully." 10 60
}

# Dynamic Storage Selection (only usable storage)
function select_storage() {
  STORAGE_OPTIONS=()
  while read -r line; do
    STORAGE=$(echo $line | awk '{print $1}')
    CONTENT=$(echo $line | awk '{print $3}')
    if [[ "$CONTENT" == *"images"* ]]; then
      STORAGE_OPTIONS+=("$STORAGE" "")
    fi
  done < <(pvesm status)

  STORAGE=$(whiptail --title "Select Storage" --menu "Choose storage for VM/Container disks" 20 60 10 "${STORAGE_OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 1
}
# Select VM or LXC
function select_type() {
  TYPE=$(whiptail --title "Select Type" --menu "Container or VM?" 10 60 2 \
    "LXC" "Linux Container" \
    "VM" "Virtual Machine" \
    3>&1 1>&2 2>&3) || exit 1
}

# Select Ubuntu or Debian
function select_os() {
  OS=$(whiptail --title "Select OS" --menu "Choose OS" 10 60 2 \
    "Ubuntu" "Ubuntu Linux" \
    "Debian" "Debian Linux" \
    3>&1 1>&2 2>&3) || exit 1
}

# Select OS Version
function select_version() {
  if [[ "$OS" == "Ubuntu" ]]; then
    VERSION=$(whiptail --title "Select Ubuntu Version" --menu "Choose Ubuntu Version" 15 60 4 \
      "18.04" "Bionic" \
      "20.04" "Focal" \
      "22.04" "Jammy" \
      "24.04" "Noble" \
      3>&1 1>&2 2>&3) || exit 1
    TEMPLATE="ubuntu-${VERSION}-standard_*.tar.zst"
    CLOUD_IMAGE="ubuntu-${VERSION}-cloudimg-amd64.img"
  else
    VERSION=$(whiptail --title "Select Debian Version" --menu "Choose Debian Version" 15 60 3 \
      "10" "Buster" \
      "11" "Bullseye" \
      "12" "Bookworm" \
      3>&1 1>&2 2>&3) || exit 1
    TEMPLATE="debian-${VERSION}-standard_*.tar.zst"
    CLOUD_IMAGE="debian-${VERSION}-genericcloud-amd64.qcow2"
  fi
}
# Prompt for general VM/Container settings
function general_settings() {
  NODE=$(whiptail --inputbox "Enter Node Name (as seen in Proxmox GUI)" 10 60 "$(hostname)" 3>&1 1>&2 2>&3) || exit 1
  select_storage
  ID=$(whiptail --inputbox "Enter VMID or CTID (must be unique)" 10 60 100 3>&1 1>&2 2>&3) || exit 1
  HOSTNAME=$(whiptail --inputbox "Enter Hostname for the machine" 10 60 "testmachine" 3>&1 1>&2 2>&3) || exit 1
  CPU=$(whiptail --inputbox "Enter number of CPU cores" 10 60 2 3>&1 1>&2 2>&3) || exit 1
  RAM=$(whiptail --inputbox "Enter amount of RAM (MB)" 10 60 2048 3>&1 1>&2 2>&3) || exit 1
  DISK=$(whiptail --inputbox "Enter disk size (GB)" 10 60 10 3>&1 1>&2 2>&3) || exit 1
  SSHKEY=$(whiptail --inputbox "Paste your SSH Public Key" 15 80 3>&1 1>&2 2>&3) || exit 1
}

# Prompt for network settings
function network_settings() {
  NET_MODE=$(whiptail --title "Network Setup" --menu "Choose network setup" 10 60 2 \
    "DHCP" "Automatic IP assignment" \
    "Static" "Manually configure IP" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$NET_MODE" == "Static" ]]; then
    IPADDR=$(whiptail --inputbox "Enter static IP address with CIDR (e.g., 192.168.1.50/24)" 10 60 3>&1 1>&2 2>&3) || exit 1
    GATEWAY=$(whiptail --inputbox "Enter Gateway IP" 10 60 3>&1 1>&2 2>&3) || exit 1
    DNS=$(whiptail --inputbox "Enter DNS Server(s) (comma-separated)" 10 60 "1.1.1.1,8.8.8.8" 3>&1 1>&2 2>&3) || exit 1
  fi
}
# Prompt for optional sudo user
function sudo_user_settings() {
  CREATE_SUDO=$(whiptail --yesno "Do you want to create an additional sudo user?" 10 60 3>&1 1>&2 2>&3) || CREATE_SUDO=false
  if [[ "$CREATE_SUDO" == "0" ]]; then
    SUDO_USER=$(whiptail --inputbox "Enter username for sudo user" 10 60 3>&1 1>&2 2>&3) || exit 1
    SUDO_PASS=$(whiptail --passwordbox "Enter password for sudo user" 10 60 3>&1 1>&2 2>&3) || exit 1
  fi
  ROOT_PASS=$(whiptail --passwordbox "Enter password for root user" 10 60 3>&1 1>&2 2>&3) || exit 1
}

# Create LXC
function create_lxc() {
  # Find the right template
  TEMPLATE_FILE=$(pveam available -section system | grep "$TEMPLATE" | awk '{print $2}' | sort -r | head -n1)
  if [ -z "$TEMPLATE_FILE" ]; then
    whiptail --title "Error" --msgbox "Could not find template matching $TEMPLATE" 10 60
    exit 1
  fi

  # Download template if missing
  if ! pveam list local | grep -q "$TEMPLATE_FILE"; then
    pveam download local "$TEMPLATE_FILE"
  fi

  pct create "$ID" "local:vztmpl/$TEMPLATE_FILE" \
    --hostname "$HOSTNAME" \
    --cores "$CPU" \
    --memory "$RAM" \
    --rootfs "$STORAGE:${DISK}G" \
    --ostype "$OS" \
    --password "$ROOT_PASS" \
    --ssh-public-keys <(echo "$SSHKEY") \
    --net0 name=eth0,bridge=vmbr0,ip=${NET_MODE,,} \
    --unprivileged 1

  if [[ "$NET_MODE" == "Static" ]]; then
    pct set "$ID" -ipconfig0 "ip=$IPADDR,gw=$GATEWAY"
  fi

  if [[ "$CREATE_SUDO" == "0" ]]; then
    pct exec "$ID" -- bash -c "useradd -m -s /bin/bash $SUDO_USER && echo '$SUDO_USER:$SUDO_PASS' | chpasswd && usermod -aG sudo $SUDO_USER"
    pct exec "$ID" -- bash -c "mkdir -p /home/$SUDO_USER/.ssh && echo '$SSHKEY' > /home/$SUDO_USER/.ssh/authorized_keys && chmod 600 /home/$SUDO_USER/.ssh/authorized_keys && chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.ssh"
  fi

  pct start "$ID"
}
# Create VM
function create_vm() {
  # Ensure the cloud image folder exists
  mkdir -p /mnt/pve/proxmox-templates/template/qcow2/

  # Check and download the cloud image if missing
  IMG_FILE="/mnt/pve/proxmox-templates/template/qcow2/$CLOUD_IMAGE"
  if [ ! -f "$IMG_FILE" ]; then
    echo "Downloading cloud image for $OS $VERSION..."
    if [[ "$OS" == "Ubuntu" ]]; then
      wget -O "$IMG_FILE" "https://cloud-images.ubuntu.com/releases/${VERSION}/release/${CLOUD_IMAGE}"
    else
      wget -O "$IMG_FILE" "https://cdimage.debian.org/cdimage/cloud/${VERSION}/latest/${CLOUD_IMAGE}"
    fi
  fi

  qm create "$ID" --name "$HOSTNAME" --memory "$RAM" --cores "$CPU" --net0 virtio,bridge=vmbr0 --ide2 "$STORAGE":cloudinit --ostype l26 --scsihw virtio-scsi-pci --scsi0 "$STORAGE":0,import-from="$IMG_FILE"
  qm set "$ID" --sshkeys <(echo "$SSHKEY")
  qm set "$ID" --ciuser root --cipassword "$ROOT_PASS"

  if [[ "$NET_MODE" == "Static" ]]; then
    qm set "$ID" --ipconfig0 "ip=$IPADDR,gw=$GATEWAY"
    qm set "$ID" --nameserver "$DNS"
  fi

  qm resize "$ID" scsi0 "${DISK}G"
  qm start "$ID"
}

# Main Script Execution Flow
select_type
select_os
select_version
general_settings
network_settings
sudo_user_settings

if [[ "$TYPE" == "LXC" ]]; then
  create_lxc
else
  create_vm
fi

build_complete
