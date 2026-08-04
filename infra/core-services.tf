# Phase 4: core cluster services every app depends on. Applied here (infra/, manual)
# rather than via ArgoCD, since MetalLB/ingress-nginx need to exist before gitops/'s
# app-of-apps (Phase 5) can rely on them for LoadBalancer IPs and Ingress routing.

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

resource "kubectl_manifest" "ingress_nginx_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ingress-nginx
  YAML

  depends_on = [kubectl_manifest.metallb_l2_advertisement]
}

# Wildcard cert (*.homelab.local) from the same local mkcert CA used for Proxmox/ArgoCD
# (see docs/implementation-plan.md, Phase 3). Set as ingress-nginx's default cert so
# every app's Ingress gets HTTPS automatically without per-app TLS config. Created before
# the helm release (not after) so the controller has the cert on its very first start,
# instead of crash-looping until it shows up.
resource "kubectl_manifest" "homelab_wildcard_tls" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: homelab-wildcard-tls
      namespace: ingress-nginx
    type: kubernetes.io/tls
    data:
      tls.crt: ${base64encode(file("${path.module}/.certs/ingress.pem"))}
      tls.key: ${base64encode(file("${path.module}/.certs/ingress-key.pem"))}
  YAML

  depends_on = [kubectl_manifest.ingress_nginx_namespace]
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "~> 4.11"
  namespace  = "ingress-nginx"

  # Gets its own MetalLB IP for HTTP(S) ingress to everything behind it.
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Pinned -- every *.homelab.local AdGuard DNS rewrite hardcodes this IP.
  # MetalLB auto-assigns otherwise, which drifted this to a different address
  # after an outage and silently broke every ingress hostname (see incident
  # notes in implementation-plan.md).
  set {
    name  = "controller.service.loadBalancerIP"
    value = "192.168.0.240"
  }

  set {
    name  = "controller.extraArgs.default-ssl-certificate"
    value = "ingress-nginx/homelab-wildcard-tls"
  }

  depends_on = [kubectl_manifest.homelab_wildcard_tls]
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

# NOTE: nfs-subdir-external-provisioner was tried here and removed. It dynamically
# creates a NEW empty subdirectory per PVC -- it can't expose an already-populated
# media tree, and it needs write access to the export root to create those
# subdirectories, which the read-only export (deliberately read-only, to protect the
# existing media) blocks outright. Static PersistentVolumes are the correct tool for
# "expose this existing read-only NFS tree" -- see gitops/apps/jellyfin-media-pv.yaml.
