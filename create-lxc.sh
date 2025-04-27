#!/usr/bin/env bash
# create-lxc.sh - revert to clean working version (before netplan changes)

set -euo pipefail

# Load defaults
source .env

LOGFILE=./create-lxc.log

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

fetch_templates() {
    log "Fetching available templates..."
    TEMPLATE_LIST_RAW=$(pveam available | awk '$1 == "system" {print $2}')
    declare -gA TEMPLATE_MAP
    while read -r template; do
        friendly=$(echo "$template" | cut -d_ -f1)
        TEMPLATE_MAP["$friendly"]="$template"
    done <<< "$TEMPLATE_LIST_RAW"
    TEMPLATE_LIST_SORTED=$(for key in "${!TEMPLATE_MAP[@]}"; do echo "$key"; done | sort)
}

select_template() {
    MENU_ITEMS=()
    for friendly in $TEMPLATE_LIST_SORTED; do
        MENU_ITEMS+=("$friendly" "")
    done
    SELECTED_FRIENDLY=$(whiptail --title "Select Template" --menu "Available Linux Templates:" 20 80 15 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
    SELECTED_TEMPLATE="${TEMPLATE_MAP[$SELECTED_FRIENDLY]}"
}

select_storage() {
    STORAGE_OPTIONS=()
    while read -r NAME TYPE STATUS _; do
        if [[ "$STATUS" == "active" && ("$NAME" == "$DEFAULT_SHARED_STORAGE" || "$TYPE" == "lvmthin") ]]; then
            STORAGE_OPTIONS+=("$NAME" "")
        fi
    done < <(pvesm status)

    STORAGE=$(whiptail --title "Select Storage" --menu "Select storage for container" 20 60 10 "${STORAGE_OPTIONS[@]}" 3>&1 1>&2 2>&3)
}

general_settings() {
    NODE=$(whiptail --inputbox "Enter Proxmox Node Name:" 10 60 "$(hostname)" 3>&1 1>&2 2>&3)
    ID=$(whiptail --inputbox "Enter CTID (Container ID Number):" 10 60 1000 3>&1 1>&2 2>&3)
    HOSTNAME=$(whiptail --inputbox "Enter Hostname:" 10 60 "testcontainer" 3>&1 1>&2 2>&3)
    CPU=$(whiptail --inputbox "Enter number of CPU cores:" 10 60 2 3>&1 1>&2 2>&3)
    RAM=$(whiptail --inputbox "Enter RAM (MB):" 10 60 2048 3>&1 1>&2 2>&3)
    DISK=$(whiptail --inputbox "Enter Disk Size (GB):" 10 60 8 3>&1 1>&2 2>&3)
    PRIV_MODE=$(whiptail --title "Container Privileges" --menu "Choose container type:" 10 60 2 Unprivileged "Better security (recommended)" Privileged "Full root access (legacy)" 3>&1 1>&2 2>&3)
    if [[ "$PRIV_MODE" == "Privileged" ]]; then
        UNPRIV=0
    else
        UNPRIV=1
    fi
}

network_settings() {
    NET_MODE=$(whiptail --title "Network Setup" --menu "Choose network setup" 10 60 2 DHCP "Automatic IP" Static "Manual IP" 3>&1 1>&2 2>&3)
    VLAN=$(whiptail --inputbox "Enter VLAN ID:" 10 60 20 3>&1 1>&2 2>&3)
}

create_lxc() {
    log "Creating LXC container..."

    # Determine storage type
    STORAGE_TYPE=$(pvesm status | awk -v storage="$STORAGE" '$1 == storage {print $2}')

    if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
        log "Allocating LVM-Thin volume..."
        pvesm alloc "$STORAGE" "$ID" "vm-${ID}-disk-0" "${DISK}G"

        log "Waiting for LVM device to appear..."
        for i in {1..10}; do
            if [[ -e "/dev/mapper/${STORAGE//-/-}-${ID//-/-}-disk-0" ]]; then
                break
            fi
            sleep 1
        done

        DEVICE="/dev/mapper/${STORAGE//-/-}-${ID//-/-}-disk-0"
        log "Formatting $DEVICE with ext4 and unprivileged options..."
        mkfs.ext4 -O uninit_bg -E root_owner=100000:100000 "$DEVICE"

        ROOTFS="$STORAGE:vm-${ID}-disk-0,size=${DISK}G"
    else
        ROOTFS="$STORAGE:8"
    fi

    if [[ "$NET_MODE" == "DHCP" ]]; then
        NET_OPTS="name=eth0,bridge=vmbr0,tag=${VLAN},ip=dhcp"
    else
        NET_OPTS="name=eth0,bridge=vmbr0,tag=${VLAN},ip=manual"
    fi

    pct create "$ID" "$DEFAULT_TEMPLATE_STORAGE:vztmpl/$SELECTED_TEMPLATE" \
        --hostname "$HOSTNAME" \
        --cores "$CPU" \
        --memory "$RAM" \
        --rootfs "$ROOTFS" \
        --net0 "$NET_OPTS" \
        --unprivileged "$UNPRIV"

    pct start "$ID"

    log "Container created and started."
}

fetch_templates
select_template
general_settings
select_storage
network_settings
create_lxc

whiptail --title Success --msgbox "\U1F389 Container created successfully!" 10 60
