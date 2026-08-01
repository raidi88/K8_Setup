# Debian 12 cloud image, imported directly by the Proxmox node (no local upload needed),
# then converted into a template that the k3s VMs clone from.

resource "proxmox_download_file" "debian_cloud_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  file_name    = "debian-12-genericcloud-amd64.qcow2"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "template" {
  name      = "debian-12-cloudinit-template"
  node_name = var.proxmox_node
  vm_id     = 9000
  template  = true

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 8
  }

  scsi_hardware = "virtio-scsi-pci"

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }

  # Placeholder cloud-init drive — actual IP/user config is set per-VM by the clones.
  initialization {
    datastore_id = "local-lvm"
    interface    = "ide2"
  }

  lifecycle {
    ignore_changes = [network_device]
  }
}
