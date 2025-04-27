#!/bin/bash
# create-lxc.sh
# Proxmox LXC Container Creator (filtered for proper container storage)

set -e

LOGFILE="./create-lxc.log"
DEFAULT_DNS="192.168.1.10,192.168.20.10,192.168.20.20"

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

function select_os_version() {
  OS=$(whiptail --title "Select OS" --menu "Choose Container OS" 10 60 2 \
    "Ubuntu" "Ubuntu Linux" \
    "Debian" "Debian Linux" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$OS" == "Ubuntu" ]]; then
    VERSION=$(whiptail --title "Select Ubuntu Version" --menu "Choose Ubuntu Version" 15 60 4 \
      "18.04" "Bionic" \
      "20.04" "Focal" \
      "22.04" "Jammy" \
      "24.04" "Noble" \
      3>&1 1>&2 2>&3) || exit 1
  else
    VERSION=$(whiptail --title "Select Debian Version" --menu "Choose Debian Version" 15 60 3 \
      "10" "Buster" \
      "11" "Bullseye" \
      "12" "Bookworm" \
      3>&1 1>&2 2>&3) || exit 1
  fi
}

function select_storage() {
  STORAGE_OPTIONS=()
  while read -r NAME TYPE STATUS TOTAL USED AVAIL PERCENT CONTENT; do
    if [[ "$STATUS" == "active" && "$CONTENT" == *"rootdir"* ]]; then
      STORAGE_OPTIONS+=("$NAME" "")
    fi
  done < <(pvesm status --verbose 2>/dev/null || pvesm status)

  # Always manually add proxmox-vmstore
  STORAGE_OPTIONS+=("proxmox-vmstore" "")

  STORAGE=$(whiptail --title "Select Storage" --menu "Choose container storage (rootdir allowed)" 20 60 10 "${STORAGE_OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 1
}

function network_settings() {
  NET_MODE=$(whiptail --title "Network Setup" --menu "Choose network setup" 10 60 2 \
    "DHCP" "Automatic IP assignment" \
    "Static" "Manually configure IP" \
    3>&1 1>&2 2>&3) || exit 1

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

function sudo_user_settings() {
  CREATE_SUDO=$(whiptail --yesno "Create a sudo user?" 10 60 3>&1 1>&2 2>&3) || CREATE_SUDO=false
  if [[ "$CREATE_SUDO" == "0" ]]; then
    SUDO_USER=$(whiptail --inputbox "Enter sudo username:" 10 60 3>&1 1>&2 2>&3) || exit 1
    SUDO_PASS=$(prompt_password_twice "sudo user password")
  fi
  ROOT_PASS=$(prompt_password_twice "root user password")
}

function general_settings() {
  NODE=$(whiptail --inputbox "Enter Proxmox Node Name:" 10 60 "$(hostname)" 3>&1 1>&2 2>&3) || exit 1
  select_storage
  ID=$(whiptail --inputbox "Enter CTID (unique container ID):" 10 60 200 3>&1 1>&2 2>&3) || exit 1
  HOSTNAME=$(whiptail --inputbox "Enter Hostname:" 10 60 "testcontainer" 3>&1 1>&2 2>&3) || exit 1
  CPU=$(whiptail --inputbox "Enter number of CPU cores:" 10 60 2 3>&1 1>&2 2>&3) || exit 1
  RAM=$(whiptail --inputbox "Enter RAM (MB):" 10 60 2048 3>&1 1>&2 2>&3) || exit 1
  DISK=$(whiptail --inputbox "Enter Disk Size (GB):" 10 60 8 3>&1 1>&2 2>&3) || exit 1
  SSHKEY=$(whiptail --inputbox "Paste SSH Public Key for root user:" 12 80 3>&1 1>&2 2>&3) || exit 1
}

function create_lxc() {
  mkdir -p /mnt/pve/proxmox-templates/template/cache/

  if [[ "$OS" == "Ubuntu" ]]; then
    TEMPLATE_MATCH="ubuntu-${VERSION}-standard_"
  else
    TEMPLATE_MATCH="debian-${VERSION}-standard_"
  fi

  TEMPLATE_FILE=$(find /mnt/pve/proxmox-templates/template/cache/ -name "${TEMPLATE_MATCH}*.tar.*" | sort -r | head -n1)

  if [ -z "$TEMPLATE_FILE" ]; then
    whiptail --title "Template Missing" --msgbox "No matching template found in proxmox-templates share!" 10 60
    exit 1
  fi

  TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")

  echo "Creating LXC container..." | tee -a "$LOGFILE"
  
  pct create "$ID" "proxmox-templates:vztmpl/$TEMPLATE_BASENAME" \
    --hostname "$HOSTNAME" \
    --cores "$CPU" \
    --memory "$RAM" \
    --rootfs "$STORAGE:${DISK}G" \
    --password "$ROOT_PASS" \
    --ssh-public-keys <(echo "$SSHKEY") \
    --net0 name=eth0,bridge=vmbr0,ip=${NET_MODE,,} \
    --unprivileged 1 2>&1 | tee -a "$LOGFILE"

  if [[ "$NET_MODE" == "Static" ]]; then
    pct set "$ID" -ipconfig0 "ip=$IPADDR,gw=$GATEWAY" 2>&1 | tee -a "$LOGFILE"
  fi

  if [[ "$CREATE_SUDO" == "0" ]]; then
    pct exec "$ID" -- bash -c "useradd -m -s /bin/bash $SUDO_USER && echo '$SUDO_USER:$SUDO_PASS' | chpasswd && usermod -aG sudo $SUDO_USER" 2>&1 | tee -a "$LOGFILE"
    pct exec "$ID" -- bash -c "mkdir -p /home/$SUDO_USER/.ssh && echo '$SSHKEY' > /home/$SUDO_USER/.ssh/authorized_keys && chmod 600 /home/$SUDO_USER/.ssh/authorized_keys && chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.ssh" 2>&1 | tee -a "$LOGFILE"
  fi

  pct start "$ID" 2>&1 | tee -a "$LOGFILE"
}

function build_complete() {
  whiptail --title "Success" --msgbox "🎉 Container created successfully!" 10 60
}

# --- Main Execution ---
select_os_version
general_settings
network_settings
sudo_user_settings
create_lxc
build_complete