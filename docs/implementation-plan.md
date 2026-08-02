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
- [x] Real bulk storage — the earlier 29GB stick was a red herring; the user has since attached the actual drives: `sdb` (7.3TB NTFS, ~6.1TB used) and `sdc` (3.6TB NTFS, ~3.3TB used), both pre-populated with an existing media library (do not wipe). Mounted **read-only** on the Proxmox host via `ntfs-3g` (persistent `/etc/fstab` entries, `UUID=`-keyed) at `/mnt/media1` and `/mnt/media2`, then NFS-exported read-only (`/etc/exports`, `192.168.0.0/24`, `ro`).
- [x] ~~`nfs-subdir-external-provisioner`~~ — tried, then removed. It dynamically creates a *new empty* subdirectory per PVC; it can't expose an already-populated tree, and it needs write access to the export root to create those subdirectories, which the deliberately-read-only export blocks. The correct tool for "expose this existing read-only NFS tree" turned out to be app-template's built-in `type: nfs` persistence (mounts the export directly, no PVC/StorageClass/provisioner needed at all) — see Jellyfin's entry in Phase 6.
- [x] Tailscale subnet router (one node), advertising the MetalLB pool range — `infra/tailscale.tf`, runs as a systemd service directly on `k3s-control-plane` (not a k8s-native pod), advertises `192.168.0.240/28` (tightest CIDR covering the MetalLB pool). Route approved in the admin console and confirmed live (`192.168.0.240/28` shows in `tailscale status --json`'s `AllowedIPs`).
- [ ] Adguard Home configured as tailnet DNS — Adguard itself is deployed and DNS-tested working (Phase 6), but pointing the tailnet at it is a manual step in the Tailscale admin console (Settings → DNS → add `192.168.0.241`, enable override) that only the user can do
- [x] sealed-secrets controller — `bitnami-labs/sealed-secrets` has moved to `bitnami/sealed-secrets`; the old `bitnami-labs.github.io` chart repo URL now 404s, use `https://bitnami.github.io/sealed-secrets` instead
- [x] Wildcard TLS for `*.homelab.local` — the mkcert local CA from Proxmox/ArgoCD (Phase 3) now also covers ingress-nginx, set as its cluster-wide `default-ssl-certificate` (`infra/core-services.tf`), so every app's Ingress gets a trusted HTTPS cert automatically with no per-app config. **Side effect worth knowing:** ingress-nginx auto-redirects HTTP→HTTPS once a default cert exists, which silently breaks any automation still using `http://` (a POST returned a bare 404 instead of a redirect) — everything scripting against these apps needs `https://` now.

**Done when:** a test LoadBalancer Service gets an IP from the MetalLB pool, a test Ingress resolves, and a test PVC binds via NFS. ✅ Fully done — MetalLB/ingress/Tailscale/TLS verified, real NFS storage attached and mounted (Jellyfin actively using it, see Phase 6).

## Phase 5 — GitOps app-of-apps

- [x] Root ArgoCD `Application` in `gitops/` pointing at child `Application` manifests — `gitops/root-app.yaml`, applied, shows `Synced`/`Healthy`
- [x] Auto-sync + prune enabled — `syncPolicy.automated.prune/selfHeal: true`
- [ ] Confirm a push to `gitops/` triggers a sync without manual intervention — can't fully verify yet since `gitops/apps/` is still empty (no child Applications to edit). Revisit once Phase 6 adds the first one.

**Required this repo have a real git remote first** — it didn't (local-only). Now pushed to [github.com/raidi88/K8_Setup](https://github.com/raidi88/K8_Setup) (public), using `gh auth login` (browser device-code flow — no API key/token ever pasted into chat).

**Done when:** editing a child Application's Helm values and pushing causes ArgoCD to reconcile automatically. ✅ Fully verified — Phase 6 involved many edit/push/sync cycles (fixing OCI chart refs, DB wiring, world-creation logic, etc.), all picked up correctly via `git push` + a hard refresh.

## Phase 6 — App rollout (in this order, per `design.md`) ✅ done

- [x] 1. Jellyfin — no official Helm chart exists; used `bjw-s-labs/helm-charts`' `app-template` (OCI, `ghcr.io/bjw-s-labs/helm` + `chart: app-template` — ArgoCD needs `chart` as a separate field even for OCI repos, `repoURL` alone isn't enough). Config on `local-path` (small, read-write). Media mounts the two real drives directly via app-template's `type: nfs` persistence — not a PVC/StorageClass, just a direct NFS mount, read-only (see Phase 4's storage entry for why `nfs-subdir-external-provisioner` doesn't work here). **Setup wizard completed via Jellyfin's own startup API** (`/startup/configuration`, `/startup/user`, `/startup/remoteaccess`, `/startup/complete` — lowercase paths; PascalCase 404s through this ingress), not the interactive UI. Automatic UPnP port mapping explicitly disabled. A `Videos` library (type `homevideos`, no metadata scraping) added pointing at both mounted drives, confirmed actively scanning. Credentials in `CREDENTIALS.md`.
  - **Gotcha 1 — config data loss on persistence restructure:** changing the `persistence` block's key names (removing `media`, adding `media1`/`media2`) caused the existing `config` PVC to get recreated rather than reused, and `local-path`'s default reclaim policy is `Delete` — so the admin account/settings were silently wiped. Caught immediately since nothing else was configured yet; redid the wizard. Worth remembering before restructuring `persistence` on an app with real data.
  - **Gotcha 2 — HTTP silently breaks after adding the wildcard TLS cert:** ingress-nginx's auto HTTP→HTTPS redirect (triggered by Phase 4's `default-ssl-certificate` change) turned a `curl -X POST http://...` into a plain 404 instead of a redirect, which looked like a routing bug rather than an HTTP-vs-HTTPS issue. `--ssl-no-revoke` + `https://` fixed it. This affects any future scripting against these apps.
- [x] 2. Nextcloud — official `nextcloud/helm` chart + bundled mariadb subchart. PVC on `local-path`, NOT NFS (still on hold). Credentials generated randomly and stored as SealedSecrets (`gitops/apps/nextcloud-*-sealedsecret.yaml`), plaintext recorded in gitignored `CREDENTIALS.md`. **Two non-obvious chart gotchas hit and fixed:** (1) `mariadb.enabled: true` alone does NOT connect the app to the DB — the app container only reads connection info from `externalDatabase.*` (mariadb is bundled but still "external" from the app's perspective), `internalDatabase.enabled` defaults to `true` (SQLite) and must be explicitly set `false`; (2) `externalDatabase.existingSecret` unconditionally requires a `db-username`-keyed entry in the secret even when `user:` is also set directly — the plain value alone doesn't satisfy the chart's template logic. Verified end-to-end via curl through MetalLB → ingress-nginx (302, Nextcloud's login redirect).
- [x] 3. Adguard Home — via app-template (no official chart). Two Services: DNS (port 53 TCP+UDP) got its own dedicated MetalLB IP `192.168.0.241`; web UI goes through ingress-nginx like the other apps (DNS isn't HTTP, can't share the ingress IP). First-run setup completed via AdGuard's own install API (`/control/install/configure`) instead of the interactive wizard — fully scriptable, no browser click-through needed. DNS rewrites added for `jellyfin`/`nextcloud`/`adguard`.homelab.local → the ingress IP. Verified with real `nslookup` queries against `192.168.0.241` — both the local rewrite and upstream passthrough (google.com) resolve correctly. Credentials in `CREDENTIALS.md`. "Configure as tailnet DNS" (Phase 4's checklist item) is still open — needs the Tailscale admin console (Settings → DNS → add `192.168.0.241` as a nameserver, enable override).
- [x] 4. Rustdesk-server — hbbs+hbbr as two containers in one pod (app-template), sharing one PVC and reaching each other via `127.0.0.1` — avoids fragile cross-pod ReadWriteOnce sharing that two separate Deployments would need. Got MetalLB IP `192.168.0.242`. Generated public key recorded in `CREDENTIALS.md` (needed to configure RustDesk clients).
- [x] 5. Minecraft — official `itzg/minecraft-server-charts`, `minecraftServer.serviceType: LoadBalancer` for a dedicated MetalLB IP `192.168.0.243`. 2-3GB memory limit sized for worker2's 8GB budget alongside adguard/rustdesk/terraria. Storage on local-path, not NFS. Verified via logs — world generated, server "Done", pod `1/1 Ready`.
- [x] 6. Terraria — plain Namespace/PVC/Deployment/Service manifests (`ryshe/terraria:vanilla-latest`), applied directly by `root-app` as flat files (same mechanism as the SealedSecrets) rather than a separate Application. Got MetalLB IP `192.168.0.244`. **Non-obvious gotcha, confirmed by testing a pod restart:** the image's `-autocreate` flag is NOT idempotent — it regenerates a brand new world from scratch every time, silently discarding the old one, since the image's own entrypoint has no "create if missing, else load" mode (only always-autocreate, or load-existing-or-fail via `WORLD_FILENAME`). Fixed with a shell wrapper (`command`/`args` in the Deployment) that checks whether the world file exists first and branches accordingly — verified via the bootstrap script's own log line ("Environment WORLD_FILENAME specified" / "Loading to world...") that a restart now loads the existing world instead of recreating it.

**Storage note for all of Phase 6:** every app above uses `local-path` (k3s's built-in default storage class) for config/small data. Jellyfin is the one exception — its media mounts the real drives directly (see its entry above). The other apps' actual content (Nextcloud files, Minecraft/Terraria worlds) are still on `local-path`, not migrated to the real drives; that's a deliberate choice, not an oversight — see the Phase 6+ note below on why.

**Done when:** each app is reachable (Ingress for web UIs, MetalLB IP for game/DNS servers) and its data persists across a pod restart. ✅ All 6 apps deployed and verified reachable; Terraria's restart-persistence explicitly tested (see its entry above) after catching a real bug where it wasn't persisting by default.

## Phase 6+ — Additions beyond the original design

Added at the user's request, same patterns as the rest of Phase 6.

- [x] qBittorrent — `linuxserver/qbittorrent` via app-template. Web UI through ingress; the torrent port (6881, TCP+UDP) gets its own dedicated MetalLB IP `192.168.0.245` since it isn't HTTP. No inbound WAN peer connectivity — no port forwarding, per the CGNAT/Tailscale design — so this only works well for LAN/tailnet-initiated activity and outbound-initiated peer/DHT connections. Started with a temporary auto-generated password (from pod first-boot logs); permanent one set via `/api/v2/auth/login` + `/api/v2/app/setPreferences` (WebUI API, no startup-config endpoint like the other apps have, but this works and persists to the config PVC). Credentials in `CREDENTIALS.md`.
- [x] Whisparr — `ghcr.io/hotio/whisparr` (the community-standard image; `linuxserver/whisparr` and `thespad/whisparr` both exist but are stale, last updated 2022). Shares qBittorrent's namespace and downloads PVC directly (`existingClaim`) rather than needing cross-namespace volume sharing. Also mounts the existing media drives read-only so it can scan/match the library, though it can't reorganize or write into it.

**Real architectural tension worth flagging:** the whole point of Whisparr/qBittorrent is downloading new content and moving it into a media folder — which needs write access. The existing media drives are deliberately read-only (protecting the pre-existing library), and there's no other real bulk-writable storage attached. Downloads currently land on a small `local-path` placeholder (10Gi) — functional for testing, not sized for real use. Scaling this up needs either new dedicated write-capable storage, or a deliberate decision to make part of the existing storage read-write (a real tradeoff against the protection that read-only currently provides, not something to change casually).

## Phase 7 — Backup

- [ ] Choose Velero (k8s-level) or Proxmox VM snapshots (simpler, coarser)
- [ ] Verify a restore actually works, not just that a backup completes

**Done when:** a deliberate test restore recovers a deleted resource or a full VM snapshot.
