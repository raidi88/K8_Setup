variable "proxmox_endpoint" {
  type    = string
  default = "https://192.168.0.150:8006/"
}

variable "proxmox_node" {
  type    = string
  default = "proxmox"
}

variable "proxmox_api_token_id" {
  type      = string
  sensitive = true
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "network_gateway" {
  type    = string
  default = "192.168.0.1"
}

variable "vm_username" {
  type    = string
  default = "raidi"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/homelab_k3s_ed25519.pub"
}
