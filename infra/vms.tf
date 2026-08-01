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

  clone {
    vm_id = proxmox_virtual_environment_vm.template.vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
    # Not "host" — full host CPU passthrough on this Zen host triggers a guest kernel
    # panic in the SRSO ("Speculative Return Stack Overflow") mitigation thunk during
    # early boot (kernel panic in srso_alias_return_thunk, reproduced twice). x86-64-v2-AES
    # is a safe, broadly-compatible profile with AES-NI that sidesteps the crash.
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

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 20
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
