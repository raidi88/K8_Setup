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

# NFS storage, one provisioner+storage class per physical media drive on the Proxmox
# host (mounted read-only there, exported via NFS — see docs/implementation-plan.md
# Phase 4 for the mount/export setup). Two separate storage classes rather than one
# because the drives are genuinely separate volumes with separate free space, not one
# combined pool.
resource "helm_release" "nfs_media1" {
  name             = "nfs-media1"
  repository       = "https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner"
  chart            = "nfs-subdir-external-provisioner"
  version          = "~> 4.0"
  namespace        = "nfs-provisioner"
  create_namespace = true

  set {
    name  = "nfs.server"
    value = "192.168.0.150"
  }
  set {
    name  = "nfs.path"
    value = "/mnt/media1"
  }
  set {
    name  = "storageClass.name"
    value = "nfs-media1"
  }
  set {
    name  = "storageClass.defaultClass"
    value = "false"
  }
  # The export itself is read-only (the drives are mounted ro on the Proxmox host to
  # protect the existing media) -- disable the provisioner's default archive-on-delete
  # behavior since it would need write access to do anything on reclaim anyway.
  set {
    name  = "storageClass.archiveOnDelete"
    value = "false"
  }

  depends_on = [null_resource.k3s_cluster]
}

resource "helm_release" "nfs_media2" {
  name             = "nfs-media2"
  repository       = "https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner"
  chart            = "nfs-subdir-external-provisioner"
  version          = "~> 4.0"
  namespace        = "nfs-provisioner"
  create_namespace = false

  set {
    name  = "nfs.server"
    value = "192.168.0.150"
  }
  set {
    name  = "nfs.path"
    value = "/mnt/media2"
  }
  set {
    name  = "storageClass.name"
    value = "nfs-media2"
  }
  set {
    name  = "storageClass.defaultClass"
    value = "false"
  }
  set {
    name  = "storageClass.archiveOnDelete"
    value = "false"
  }

  depends_on = [helm_release.nfs_media1]
}
