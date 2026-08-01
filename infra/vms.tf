locals {
  vms = {
    control-plane = { vm_id = 8001, cores = 2, memory = 4096, ip = "192.168.0.151/24" }
    worker1       = { vm_id = 8002, cores = 4, memory = 8192, ip = "192.168.0.152/24" }
    worker2       = { vm_id = 8003, cores = 4, memory = 8192, ip = "192.168.0.153/24" }
  }

  # Real target OS disk size. Stays separate from the disk.size=3 clone-time value
  # below on purpose — see null_resource.grow_disk for why.
  vm_disk_size_gb = 20
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each = local.vms

  name      = "k3s-${each.key}"
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  depends_on = [null_resource.import_template_disk]

  clone {
    vm_id = proxmox_virtual_environment_vm.template.vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
    # x86-64-v2-AES rather than "host" passthrough — not required for correctness (the
    # actual boot-crashing bug turned out to be the provider's file_id disk-creation path,
    # fixed in template.tf), but it's a safe, broadly-compatible baseline with AES-NI.
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  # qemu-guest-agent isn't installed in the base Debian cloud image, so leaving this
  # enabled makes Terraform block for ~10+ min waiting for a response that never comes.
  # We already know the IPs via static cloud-init config, so we don't need it yet.
  # Revisit once cloud-init installs the agent package (Phase 2+).
  agent {
    enabled = false
  }

  # size is REQUIRED here and must match the template's native disk size (3G) exactly.
  # Omitting it entirely makes the provider silently default to 8G and issue a resize
  # task right after cloning — confirmed via Proxmox's own task log (qmclone, then a
  # separate "resize" task, every time) — and that resize is what corrupts the root
  # filesystem (identical guest kernel panic reproduced 3 times). Growing disks safely
  # (via `qm resize` + a reboot, letting cloud-init's growpart/resize2fs extend the
  # filesystem on an already-booted disk) is a follow-up; see docs/implementation-plan.md.
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 3
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = "local-lvm"
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.network_gateway]
    }

    user_account {
      username = var.vm_username
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  # null_resource.grow_disk (below) grows the real disk out-of-band after boot. Without
  # this, Terraform sees that drift against disk.size=3 and tries to shrink it back on
  # the next apply — which would either fail or, worse, attempt a destructive shrink.
  lifecycle {
    ignore_changes = [disk]
  }
}

# Grows each VM's OS disk from the corruption-safe 3G clone size up to the real target
# size, *after* the VM has already booted successfully. This is the safe way to do it:
# `qm resize` only extends the underlying block device (no partition/filesystem rewrite,
# so nothing to corrupt), and growpart/resize2fs then extend the already-mounted,
# already-healthy filesystem in place. Contrast with resizing before first boot, which
# is what corrupted every VM earlier (see vms.tf's disk block and template.tf).
resource "null_resource" "grow_disk" {
  for_each = local.vms

  depends_on = [proxmox_virtual_environment_vm.k3s]

  triggers = {
    vm_id     = each.value.vm_id
    disk_size = local.vm_disk_size_gb
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      VM_IP="${split("/", each.value.ip)[0]}"
      GUEST_SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i ~/.ssh/homelab_k3s_ed25519 ${var.vm_username}@$VM_IP"

      for i in $(seq 1 30); do
        $GUEST_SSH true && break
        sleep 5
      done

      ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/homelab_k3s_ed25519 root@${var.proxmox_ssh_host} \
        "qm resize ${each.value.vm_id} scsi0 ${local.vm_disk_size_gb}G" || true

      $GUEST_SSH "sudo growpart /dev/sda 1 || true; sudo resize2fs /dev/sda1"
    EOT
  }
}
