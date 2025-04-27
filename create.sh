#!/bin/bash
# create.sh - Main Launcher

CHOICE=$(whiptail --title "Proxmox Installer" --menu "Choose an option:" 15 60 2   "VM" "Create a Virtual Machine"   "LXC" "Create a Linux Container" 3>&1 1>&2 2>&3)

case $CHOICE in
  VM)
    ./create-vm.sh
    ;;
  LXC)
    ./create-lxc.sh
    ;;
esac
