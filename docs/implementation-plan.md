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

- [x] MetalLB (L2 mode), IP pool sized for all planned LoadBalancer services — `192.168.0.240-192.168.0.250`, picked after an `nmap -sn` sweep of the LAN found only .1/.150-153/.179 active. Flag if this overlaps your router's DHCP range.
- [x] ingress-nginx — confirmed working end-to-end: its controller Service got `192.168.0.240`, the first address in the MetalLB pool
- [ ] `nfs-subdir-external-provisioner`, pointed at the host's NFS export of the USB HDD — **on hold**: the only USB storage attached to the Proxmox host is a 29GB stick (`lsusb`/`lsblk` confirm it), not a bulk-storage HDD. User is holding off on this for now.
- [x] Tailscale subnet router (one node), advertising the MetalLB pool range — `infra/tailscale.tf`, runs as a systemd service directly on `k3s-control-plane` (not a k8s-native pod), advertises `192.168.0.240/28` (tightest CIDR covering the MetalLB pool). Route approved in the admin console and confirmed live (`192.168.0.240/28` shows in `tailscale status --json`'s `AllowedIPs`).
- [ ] Adguard Home configured as tailnet DNS (later, once Adguard itself is deployed in Phase 6)
- [x] sealed-secrets controller — `bitnami-labs/sealed-secrets` has moved to `bitnami/sealed-secrets`; the old `bitnami-labs.github.io` chart repo URL now 404s, use `https://bitnami.github.io/sealed-secrets` instead

**Done when:** a test LoadBalancer Service gets an IP from the MetalLB pool, a test Ingress resolves, and a test PVC binds via NFS. Mostly done — MetalLB/ingress/Tailscale verified, NFS on hold pending the right hardware.

## Phase 5 — GitOps app-of-apps

- [x] Root ArgoCD `Application` in `gitops/` pointing at child `Application` manifests — `gitops/root-app.yaml`, applied, shows `Synced`/`Healthy`
- [x] Auto-sync + prune enabled — `syncPolicy.automated.prune/selfHeal: true`
- [ ] Confirm a push to `gitops/` triggers a sync without manual intervention — can't fully verify yet since `gitops/apps/` is still empty (no child Applications to edit). Revisit once Phase 6 adds the first one.

**Required this repo have a real git remote first** — it didn't (local-only). Now pushed to [github.com/raidi88/K8_Setup](https://github.com/raidi88/K8_Setup) (public), using `gh auth login` (browser device-code flow — no API key/token ever pasted into chat).

**Done when:** editing a child Application's Helm values and pushing causes ArgoCD to reconcile automatically. Mostly done — root app confirmed syncing from the real repo; full edit-and-reconcile test pending Phase 6.

## Phase 6 — App rollout (in this order, per `design.md`)

- [x] 1. Jellyfin — no official Helm chart exists; used `bjw-s-labs/helm-charts`' `app-template` (OCI, `ghcr.io/bjw-s-labs/helm` + `chart: app-template` — ArgoCD needs `chart` as a separate field even for OCI repos, `repoURL` alone isn't enough). PVC on `local-path`, NOT NFS (still on hold) — small placeholder sizes (1Gi config / 5Gi media), migrate once real storage is available. Verified end-to-end via curl through MetalLB → ingress-nginx (302, Jellyfin's setup-wizard redirect).
- [x] 2. Nextcloud — official `nextcloud/helm` chart + bundled mariadb subchart. PVC on `local-path`, NOT NFS (still on hold). Credentials generated randomly and stored as SealedSecrets (`gitops/apps/nextcloud-*-sealedsecret.yaml`), plaintext recorded in gitignored `CREDENTIALS.md`. **Two non-obvious chart gotchas hit and fixed:** (1) `mariadb.enabled: true` alone does NOT connect the app to the DB — the app container only reads connection info from `externalDatabase.*` (mariadb is bundled but still "external" from the app's perspective), `internalDatabase.enabled` defaults to `true` (SQLite) and must be explicitly set `false`; (2) `externalDatabase.existingSecret` unconditionally requires a `db-username`-keyed entry in the secret even when `user:` is also set directly — the plain value alone doesn't satisfy the chart's template logic. Verified end-to-end via curl through MetalLB → ingress-nginx (302, Nextcloud's login redirect).
- [x] 3. Adguard Home — via app-template (no official chart). Two Services: DNS (port 53 TCP+UDP) got its own dedicated MetalLB IP `192.168.0.241`; web UI goes through ingress-nginx like the other apps (DNS isn't HTTP, can't share the ingress IP). DNS queries won't resolve yet — AdGuard redirects to its first-run setup wizard (`/install.html`) until you complete it interactively (admin password, upstream DNS choice) at `http://adguard.homelab.local`. "Configure as tailnet DNS" (per Phase 4's checklist) is a further manual step in the Tailscale admin console once that's done.
- [ ] 4. Rustdesk-server — hbbs/hbbr only, PVC for ID keys
- [ ] 5. Minecraft — `itzg/minecraft-server` chart, NFS PVC, dedicated MetalLB IP
- [ ] 6. Terraria — plain Deployment/Service/PVC, TCP 7777, dedicated MetalLB IP

**Done when:** each app is reachable (Ingress for web UIs, MetalLB IP for game/DNS servers) and its data persists across a pod restart.

## Phase 7 — Backup

- [ ] Choose Velero (k8s-level) or Proxmox VM snapshots (simpler, coarser)
- [ ] Verify a restore actually works, not just that a backup completes

**Done when:** a deliberate test restore recovers a deleted resource or a full VM snapshot.
