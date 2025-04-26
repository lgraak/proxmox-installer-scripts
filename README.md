# Proxmox Installer Scripts

A simple interactive script to deploy Ubuntu or Debian LXC containers and VMs on Proxmox VE.
- Choose LXC or VM
- Choose Ubuntu or Debian
- Select OS version
- Configure CPU, RAM, disk, storage
- Set static IP or DHCP
- Setup root user and optional sudo user with SSH key

## Usage

1. SSH into your Proxmox node.
2. Upload the script or clone this repository.
3. Run:

```bash
chmod +x proxmox-installer.sh
./proxmox-installer.sh
```

## Requirements

- Proxmox VE 7.x or 8.x
- SSH public key ready for injection
- Cloud-Init for VM creation
