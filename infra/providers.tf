terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true

  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand("~/.ssh/homelab_k3s_ed25519"))
  }
}

# Points at the kubeconfig null_resource.k3s_cluster writes out. This is a static path,
# read lazily when helm_release actually talks to the API — not at plan time — so it's
# fine that the file doesn't exist yet on a from-scratch apply, as long as
# helm_release.argocd depends_on the k3s bootstrap.
provider "helm" {
  kubernetes {
    config_path = "${path.module}/kubeconfig"
  }
}
