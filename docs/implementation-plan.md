# Implementation Plan

Derived from [`design.md`](design.md). Worked phase by phase, pair-programming style — each phase should be a working, verifiable checkpoint before moving to the next. Nothing here is applied yet; `infra/` and `gitops/` currently hold only placeholders.

## Phase 0 — Prep (manual, outside the repo)

- [x] Proxmox API token created for Terraform (`bpg/proxmox` provider auth) — `root@pam!terraform`, full permissions, privilege separation off
- [x] SSH keypair generated for cloud-init to inject into VMs — `~/.ssh/homelab_k3s_ed25519`, also added to root's `authorized_keys` on the Proxmox host itself and to `~/.ssh/config` as `proxmox`/`k3s-control-plane`/`k3s-worker1`/`k3s-worker2` aliases
- [x] Confirm Proxmox storage pool name, network bridge name, and a cloud-init-ready base image are available on the host — `local` (import/iso) + `local-lvm` (disks), `vmbr0` already existed, Debian 12 genericcloud image downloaded directly by Terraform
- [ ] External USB HDD mounted on the Proxmox host, ready to be NFS-exported — deferred to Phase 4 (storage)

**Done when:** you can reach the Proxmox API with the token via `curl`/`pvesh`, and the base cloud image exists on the target storage. ✅

## Phase 1 — Terraform VM provisioning (`infra/`) ✅ done

- [x] `bpg/proxmox` provider config, local state (gitignored)
- [x] Cloud-init template resource (static IP, SSH key, base packages)
- [x] 3 VM resources per the RAM/vCPU table in `design.md`:
  - control-plane — 4GB / 2 vCPU — 192.168.0.151
  - worker1 — 8GB / 4 vCPU — 192.168.0.152
  - worker2 — 8GB / 4 vCPU — 192.168.0.153
- [x] `variables.tf` + `terraform.tfvars.example` (real `terraform.tfvars` gitignored)
- [x] `outputs.tf` exposing the 3 VM IPs

**Done when:** `terraform apply` (run manually, reviewed via `plan` first) brings up 3 VMs reachable over SSH with their static IPs. ✅ Verified — all 3 VMs boot cleanly and are SSH-reachable at their static IPs, 20GB disks.

**Hard-won lessons (see commit history for full detail):**
- The `bpg/proxmox` provider's built-in `file_id`-based disk creation and its clone-time disk resize both route through a buggy conversion/resize path that reproducibly corrupted the guest filesystem (identical kernel panic, "Attempted to kill init!", every time — not a CPU or agent issue, despite those being tried first). Root-caused by manually reproducing each step outside Terraform with Proxmox's native `qm importdisk`/`qm clone`/`qm resize`, which don't have the bug.
- Fix: build the template disk via `qm importdisk` (a `null_resource` + `local-exec`, not the provider's native disk resource), pin clone disk `size` to match the template exactly (no implicit resize), then grow disks safely *after* first boot via `qm resize` (block-device-only, no partition rewrite) + in-guest `growpart`/`resize2fs`.
- `agent.enabled = true` hangs Terraform for 10+ minutes per VM since `qemu-guest-agent` isn't installed in the base Debian cloud image — left disabled for now (static IPs from cloud-init make it unnecessary so far).

## Phase 2 — k3s cluster bootstrap ✅ done

- [x] Install k3s server on control-plane with `--disable traefik`
- [x] Install k3s agent on worker1 and worker2, joined via the server's token
- [x] Pull `kubeconfig` off control-plane for local `kubectl` access — `infra/kubeconfig` (gitignored)

**Done when:** `kubectl get nodes` shows all 3 nodes `Ready` from your workstation. ✅ Verified.

**Hard-won lesson:** each VM independently downloading the ~80MB k3s binary from GitHub took 20-30+ minutes on this network — confirmed as a genuine link-level bottleneck (a Debian mirror and Rancher's own mirror were equally slow at the time), not GitHub-specific throttling. Fixed by fetching the binary once to a local, resumable, checksum-verified cache and pushing it to all 3 VMs over the fast LAN (`infra/k3s.tf`), installing with `INSTALL_K3S_SKIP_DOWNLOAD=true` instead of letting each node hit GitHub itself.

## Phase 3 — One-time manual seam: Helm + ArgoCD ✅ done

- [x] Install Helm on control-plane (or from workstation against the cluster) — used Terraform's `hashicorp/helm` provider from the workstation instead (`infra/argocd.tf`), not a manual CLI install
- [x] Install ArgoCD via its Helm chart
- [x] Retrieve ArgoCD admin password, confirm UI/CLI access — reachable via `kubectl port-forward svc/argocd-server -n argocd 8080:443`, credentials in the gitignored `CREDENTIALS.md`

**Done when:** `argocd app list` runs successfully (empty list is fine) — this is the last manually-applied step before GitOps takes over. ✅ Verified — all 7 pods `Running`, UI reachable.

**Extra (not in the original design, done at the user's request):** both the Proxmox UI and ArgoCD had self-signed-cert browser warnings. Fixed with a local trusted CA via `mkcert` (installed to the Windows system trust store), certs deployed to `pveproxy` on the Proxmox host and as a `argocd-server-tls` secret for `argocd-server`. Cert/key files live in `infra/.certs/` (gitignored).

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
