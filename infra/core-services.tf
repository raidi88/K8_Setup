# Phase 4: core cluster services every app depends on. Applied here (infra/, manual)
# rather than via ArgoCD, since MetalLB/ingress-nginx need to exist before gitops/'s
# app-of-apps (Phase 5) can rely on them for LoadBalancer IPs and Ingress routing.
#
# NFS provisioner and Tailscale are deliberately NOT here yet — NFS needs the external
# USB HDD mounted + exported on the Proxmox host first (Phase 0, not done), and Tailscale
# needs an auth key from the user's own account. Both follow once those are available.

resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = "~> 0.14"
  namespace        = "metallb-system"
  create_namespace = true

  depends_on = [null_resource.k3s_cluster]
}

# IP pool scanned as unused on the LAN (192.168.0.0/24) — only .1 (gateway), .150-153
# (Proxmox + VMs), and .179 (some other DHCP client) showed up in an nmap sweep. Flagged
# to the user in case it overlaps their router's DHCP range; adjust if so.
resource "kubectl_manifest" "metallb_pool" {
  yaml_body = <<-YAML
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: default-pool
      namespace: metallb-system
    spec:
      addresses:
        - 192.168.0.240-192.168.0.250
  YAML

  depends_on = [helm_release.metallb]
}

resource "kubectl_manifest" "metallb_l2_advertisement" {
  yaml_body = <<-YAML
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: default-l2
      namespace: metallb-system
    spec:
      ipAddressPools:
        - default-pool
  YAML

  depends_on = [kubectl_manifest.metallb_pool]
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "~> 4.11"
  namespace        = "ingress-nginx"
  create_namespace = true

  # Gets its own MetalLB IP for HTTP(S) ingress to everything behind it.
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  depends_on = [kubectl_manifest.metallb_l2_advertisement]
}

# The bitnami-labs/sealed-secrets repo moved to bitnami/sealed-secrets (org rename);
# the old bitnami-labs.github.io chart index now 404s.
resource "helm_release" "sealed_secrets" {
  name             = "sealed-secrets"
  repository       = "https://bitnami.github.io/sealed-secrets"
  chart            = "sealed-secrets"
  version          = "~> 2.16"
  namespace        = "kube-system"
  create_namespace = false

  depends_on = [null_resource.k3s_cluster]
}
