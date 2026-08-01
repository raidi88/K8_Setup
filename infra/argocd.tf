# Phase 3: the one manual bootstrap seam between infra/ and gitops/, per design.md.
# After this, ArgoCD (via its app-of-apps root Application in gitops/, added in Phase 5)
# takes over everything else — auto-sync + prune on every push.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "~> 7.7"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [null_resource.k3s_cluster]
}
