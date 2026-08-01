# Phase 2: k3s cluster bootstrap. Installs k3s server on control-plane (Traefik
# disabled — ingress-nginx comes later, for clearer/more standard k8s learning per
# design.md), joins both workers via the server's node token, then pulls a kubeconfig
# back to infra/kubeconfig (gitignored) for local `kubectl` access.
#
# Same null_resource + SSH pattern as template.tf/vms.tf, kept consistent rather than
# introducing Ansible as a second provisioning tool.
#
# The k3s binary is fetched ONCE to a local cache (gitignored, resumable via `curl -C -`)
# and checksum-verified, then pushed to all 3 VMs over the fast local LAN and installed
# with INSTALL_K3S_SKIP_DOWNLOAD=true. Each VM independently curling ~80MB from GitHub
# was taking 20-30+ minutes on this network — fetching it once and distributing locally
# turned that into seconds per VM.

locals {
  k3s_version    = "v1.36.2+k3s1"
  k3s_binary_url = "https://github.com/k3s-io/k3s/releases/download/${replace(local.k3s_version, "+", "%2B")}/k3s"
  k3s_sha256_url = "https://github.com/k3s-io/k3s/releases/download/${replace(local.k3s_version, "+", "%2B")}/sha256sum-amd64.txt"
  k3s_cache_path = "${path.module}/.cache/k3s-${local.k3s_version}.bin"
}

resource "null_resource" "k3s_cluster" {
  depends_on = [null_resource.grow_disk]

  triggers = {
    control_plane_id = local.vms["control-plane"].vm_id
    worker1_id       = local.vms["worker1"].vm_id
    worker2_id       = local.vms["worker2"].vm_id
    k3s_version      = local.k3s_version
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CP_IP="${split("/", local.vms["control-plane"].ip)[0]}"
      W1_IP="${split("/", local.vms["worker1"].ip)[0]}"
      W2_IP="${split("/", local.vms["worker2"].ip)[0]}"
      SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i ~/.ssh/homelab_k3s_ed25519"
      USER="${var.vm_username}"
      CACHE="${local.k3s_cache_path}"

      mkdir -p "$(dirname "$CACHE")"

      echo "== fetching k3s binary once (resumable) =="
      EXPECTED_SHA=$(curl -sfL "${local.k3s_sha256_url}" | grep '  k3s$' | awk '{print $1}')
      if [ ! -f "$CACHE" ] || [ "$(sha256sum "$CACHE" | awk '{print $1}')" != "$EXPECTED_SHA" ]; then
        curl -C - -o "$CACHE" -sfL "${local.k3s_binary_url}"
      fi
      ACTUAL_SHA=$(sha256sum "$CACHE" | awk '{print $1}')
      if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        echo "checksum mismatch: expected $EXPECTED_SHA got $ACTUAL_SHA" >&2
        exit 1
      fi

      echo "== pushing binary to all 3 VMs over the LAN =="
      for VM_IP in "$CP_IP" "$W1_IP" "$W2_IP"; do
        scp -o StrictHostKeyChecking=accept-new -i ~/.ssh/homelab_k3s_ed25519 "$CACHE" "$USER@$VM_IP:/tmp/k3s.bin"
        ssh $SSH_OPTS "$USER@$VM_IP" 'sudo cp /tmp/k3s.bin /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s'
      done

      echo "== installing k3s server on control-plane =="
      ssh $SSH_OPTS "$USER@$CP_IP" \
        'curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_DOWNLOAD=true sudo -E sh -s - --disable traefik --write-kubeconfig-mode 644'

      TOKEN=$(ssh $SSH_OPTS "$USER@$CP_IP" 'sudo cat /var/lib/rancher/k3s/server/node-token')

      for WORKER_IP in "$W1_IP" "$W2_IP"; do
        echo "== joining worker $WORKER_IP =="
        ssh $SSH_OPTS "$USER@$WORKER_IP" \
          "curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_DOWNLOAD=true K3S_URL=https://$CP_IP:6443 K3S_TOKEN=$TOKEN sudo -E sh -"
      done

      echo "== fetching kubeconfig =="
      ssh $SSH_OPTS "$USER@$CP_IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$CP_IP/" > "${path.module}/kubeconfig"
      chmod 600 "${path.module}/kubeconfig"
    EOT
  }
}
