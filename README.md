# Proxmox Installer Scripts

Quickly create VMs and LXCs in a Proxmox environment with customized options, static or DHCP networking, VLAN tagging, and SSH key injection.

---

## ✨ Features

- Create **Ubuntu** or **Debian** VMs
- Create **Ubuntu** or **Debian** LXCs (separate script)
- **Cloud-Init** support for SSH keys and network settings
- **VLAN tagging** supported on VM creation
- Supports both **Static IP** and **DHCP** setups
- **UEFI BIOS** and **q35 machine type** for VMs
- **Automatic download** of missing cloud-init images
- **Environment variables** for easy customization (`.env` file)
- **Logging**: VM/LXC creation actions are logged to `.log` files
- **Storage selection**: Choose between detected local storage or shared storage
- Clean error handling if `.env` is missing

---

## 📦 Included Scripts

| Script | Purpose |
|:---|:---|
| `create.sh` | Menu launcher for choosing VM or LXC creation |
| `create-vm.sh` | VM creation script |
| `create-lxc.sh` | LXC container creation script |
| `.env-template` | Template for environment variables |
| `.gitignore` | Ensures private and generated files are not pushed |

---

## 🛠 Requirements

- Proxmox VE 7.x or newer
- NFS shared storage (optional but recommended)
- Bash, Whiptail, SSH keys ready
- Installed Cloud-Init support package in Proxmox
- Internet access for downloading cloud images (or pre-seeded images)

---

## 📖 How To Set Up

1. Clone the repository:

   ```bash
   git clone git@github.com:yourname/proxmox-installer-scripts.git
   cd proxmox-installer-scripts
