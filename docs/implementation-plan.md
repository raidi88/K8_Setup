# Implementation Plan

Derived from [`design.md`](design.md). Worked phase by phase, pair-programming style — each phase should be a working, verifiable checkpoint before moving to the next. Nothing here is applied yet; `infra/` and `gitops/` currently hold only placeholders.

## Phase 0 — Prep (manual, outside the repo)

- [ ] Proxmox API token created for Terraform (`bpg/proxmox` provider auth)
- [ ] SSH keypair generated for cloud-init to inject into VMs
- [ ] Confirm Proxmox storage pool name, network bridge name, and a cloud-init-ready base image (e.g. Debian/Ubuntu cloud image) are available on the host
- [ ] External USB HDD mounted on the Proxmox host, ready to be NFS-exported

**Done when:** you can reach the Proxmox API with the token via `curl`/`pvesh`, and the base cloud image exists on the target storage.

## Phase 1 — Terraform VM provisioning (`infra/`)

- [ ] `bpg/proxmox` provider config, local state (gitignored)
- [ ] Cloud-init template resource (static IP, SSH key, base packages)
- [ ] 3 VM resources per the RAM/vCPU table in `design.md`:
  - control-plane — 4GB / 2 vCPU
  - worker1 — 8GB / 4 vCPU
  - worker2 — 8GB / 4 vCPU
- [ ] `variables.tf` + `terraform.tfvars.example` (real `terraform.tfvars` gitignored)
- [ ] `outputs.tf` exposing the 3 VM IPs

**Done when:** `terraform apply` (run manually, reviewed via `plan` first) brings up 3 VMs reachable over SSH with their static IPs.

## Phase 2 — k3s cluster bootstrap

- [ ] Install k3s server on control-plane with `--disable traefik`
- [ ] Install k3s agent on worker1 and worker2, joined via the server's token
- [ ] Pull `kubeconfig` off control-plane for local `kubectl` access

**Done when:** `kubectl get nodes` shows all 3 nodes `Ready` from your workstation.

## Phase 3 — One-time manual seam: Helm + ArgoCD

- [ ] Install Helm on control-plane (or from workstation against the cluster)
- [ ] Install ArgoCD via its Helm chart
- [ ] Retrieve ArgoCD admin password, confirm UI/CLI access

**Done when:** `argocd app list` runs successfully (empty list is fine) — this is the last manually-applied step before GitOps takes over.

## Phase 4 — Core cluster services

These are the shared platform pieces every app depends on. Can be applied via ArgoCD (as the first synced apps) or manually before GitOps takes over — decide when we get here.

- [ ] MetalLB (L2 mode), IP pool sized for all planned LoadBalancer services
- [ ] ingress-nginx
- [ ] `nfs-subdir-external-provisioner`, pointed at the host's NFS export of the USB HDD
- [ ] Tailscale subnet router (one node), advertising the MetalLB pool range
- [ ] Adguard Home configured as tailnet DNS (later, once Adguard itself is deployed in Phase 6)
- [ ] sealed-secrets controller

**Done when:** a test LoadBalancer Service gets an IP from the MetalLB pool, a test Ingress resolves, and a test PVC binds via NFS.

## Phase 5 — GitOps app-of-apps

- [ ] Root ArgoCD `Application` in `gitops/` pointing at child `Application` manifests
- [ ] Auto-sync + prune enabled
- [ ] Confirm a push to `gitops/` triggers a sync without manual intervention

**Done when:** editing a child Application's Helm values and pushing causes ArgoCD to reconcile automatically.

## Phase 6 — App rollout (in this order, per `design.md`)

- [ ] 1. Jellyfin — Helm chart, NFS PVC for media
- [ ] 2. Nextcloud — Helm chart + mariadb subchart, NFS PVC for files
- [ ] 3. Adguard Home — MetalLB LoadBalancer IP, port 53
- [ ] 4. Rustdesk-server — hbbs/hbbr only, PVC for ID keys
- [ ] 5. Minecraft — `itzg/minecraft-server` chart, NFS PVC, dedicated MetalLB IP
- [ ] 6. Terraria — plain Deployment/Service/PVC, TCP 7777, dedicated MetalLB IP

**Done when:** each app is reachable (Ingress for web UIs, MetalLB IP for game/DNS servers) and its data persists across a pod restart.

## Phase 7 — Backup

- [ ] Choose Velero (k8s-level) or Proxmox VM snapshots (simpler, coarser)
- [ ] Verify a restore actually works, not just that a backup completes

**Done when:** a deliberate test restore recovers a deleted resource or a full VM snapshot.
