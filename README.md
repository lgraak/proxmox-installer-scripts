# Proxmox Installer Scripts (v2)

A professional Proxmox LXC/VM builder with:
- Ubuntu and Debian support (18.04/20.04/22.04/24.04, Debian 10/11/12)
- Dynamic storage picker
- Static or DHCP networking
- SSH key injection for root and optional sudo user
- Auto-download cloud images to `/mnt/pve/proxmox-templates/template/qcow2/`

## Usage

```bash
chmod +x proxmox-installer.sh
./proxmox-installer.sh
```

## Requirements
- `/mnt/pve/proxmox-templates` must exist and be mounted
- Node must have internet access initially for image downloads
