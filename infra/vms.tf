locals {
  vms = {
    control-plane = { vm_id = 8001, cores = 2, memory = 4096, ip = "192.168.0.151/24" }
    worker1       = { vm_id = 8002, cores = 4, memory = 8192, ip = "192.168.0.152/24" }
    worker2       = { vm_id = 8003, cores = 4, memory = 8192, ip = "192.168.0.153/24" }
  }
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
}
