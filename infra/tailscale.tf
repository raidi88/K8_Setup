# Phase 4 (continued): Tailscale subnet router. Runs as a systemd service directly on
# k3s-control-plane (the always-on node), advertising just the MetalLB pool range —
# not the whole LAN — per design.md. Solves remote access without port forwarding
# (blocked by CGNAT) or a public domain.
#
# Note: even with a pre-authorized auth key, Tailscale's admin console still requires a
# manual approval toggle for advertised *subnet routes* specifically (separate from
# device approval) unless the tailnet has route auto-approval configured in its ACLs.
# Check https://login.tailscale.com/admin/machines after this applies.

locals {
  # Tightest CIDR covering the MetalLB pool (192.168.0.240-192.168.0.250).
  tailscale_advertised_route = "192.168.0.240/28"
}

resource "null_resource" "tailscale_subnet_router" {
  depends_on = [null_resource.k3s_cluster]

  triggers = {
    control_plane_id = local.vms["control-plane"].vm_id
    route            = local.tailscale_advertised_route
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CP_IP="${split("/", local.vms["control-plane"].ip)[0]}"
      SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i ~/.ssh/homelab_k3s_ed25519"
      USER="${var.vm_username}"

      ssh $SSH_OPTS "$USER@$CP_IP" '
        if ! command -v tailscale >/dev/null 2>&1; then
          curl -fsSL https://tailscale.com/install.sh | sudo sh
        fi
        sudo sysctl -w net.ipv4.ip_forward=1
        sudo sysctl -w net.ipv6.conf.all.forwarding=1
        echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-tailscale.conf
        echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.d/99-tailscale.conf
      '

      ssh $SSH_OPTS "$USER@$CP_IP" \
        "sudo tailscale up --authkey=${var.tailscale_auth_key} --advertise-routes=${local.tailscale_advertised_route} --accept-routes --hostname=k3s-control-plane"
    EOT
  }
}
