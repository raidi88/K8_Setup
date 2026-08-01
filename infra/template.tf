# Debian 12 cloud image, imported directly by the Proxmox node (no local upload needed).
#
# The disk is attached via `qm importdisk` (Proxmox's own native import tool) rather
# than the provider's built-in file_id-based disk creation. That built-in path routes
# through an SSH-based conversion+resize step that reproducibly corrupted the root
# filesystem (guest kernel panic, "Attempted to kill init!", identical every time
# regardless of CPU type/agent settings) — confirmed by manually reproducing the same
# import with `qm importdisk` instead, which boots cleanly. See docs/implementation-plan.md.

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
  started   = false

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 1024
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

  # scsi0 and the "template" flag are set out-of-band by null_resource.import_template_disk
  # below — Terraform never sees them as part of this resource's own config.
  lifecycle {
    ignore_changes = [network_device, disk, template]
  }
}

resource "null_resource" "import_template_disk" {
  depends_on = [proxmox_virtual_environment_vm.template, proxmox_download_file.debian_cloud_image]

  triggers = {
    template_vm_id = proxmox_virtual_environment_vm.template.vm_id
    image_id       = proxmox_download_file.debian_cloud_image.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      VMID=${proxmox_virtual_environment_vm.template.vm_id}
      ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/homelab_k3s_ed25519 root@${var.proxmox_ssh_host} "
        qm importdisk $VMID /var/lib/vz/import/debian-12-genericcloud-amd64.qcow2 local-lvm &&
        qm set $VMID --scsi0 local-lvm:vm-$${VMID}-disk-0 &&
        qm set $VMID --boot order=scsi0 &&
        qm template $VMID
      "
    EOT
  }
}
