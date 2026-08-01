# Homelab k3s + GitOps Design

**Date:** 2026-07-30
**Goal:** Learn Kubernetes essentials (nodes, Helm, ArgoCD, ingress, storage) hands-on, while self-hosting a few genuinely useful services, fully managed as code.

## Hardware

Beelink SER5 MAX, Ryzen 7 5800H (8c/16t), 24GB RAM, 500GB internal SSD. Running Proxmox VE already. External USB HDD attached for bulk storage (media, files, game worlds) — no separate NAS device.

No port forwarding available (ISP blocks it / CGNAT). No public domain purchased.

## Repo structure (GitHub)

```
homelab-k8s/
  infra/     # Terraform (bpg/proxmox provider) — VM provisioning + cloud-init
  gitops/    # ArgoCD Applications + Helm values per app
```

Two-speed management, matching existing work habits:
- `infra/` — Terraform, **manual local apply only**. Review `plan`, apply yourself. No CI automation for the infra layer.
- `gitops/` — ArgoCD, **auto-sync + prune** on every push to the repo. This is the "everything as code, hands-off" layer.

## Infra layer (Terraform)

Provider: `bpg/proxmox` (actively maintained, more complete than `telmate/proxmox`).

3 VMs on the Beelink:

| VM | RAM | vCPU | Workloads |
|---|---|---|---|
| control-plane | 4GB | 2 | k3s control-plane only |
| worker1 | 8GB | 4 | nextcloud, jellyfin |
| worker2 | 8GB | 4 | adguard, rustdesk-server, minecraft, terraria |

Proxmox host overhead: ~4GB reserved (headless hypervisor, no GUI). Total: 24GB, fully allocated — no slack left. If Minecraft goes modded/heavy, revisit jellyfin transcoding load or add RAM.

Cloud-init handles: static IPs, SSH keys, base packages.

State: local `.tfstate` file, **not committed to git** (`.gitignore`d). Solo operator, no remote backend needed — remote state/locking is unnecessary complexity for one person. Revisit only if ever applying from multiple machines (e.g. self-hosted MinIO as S3-compatible backend, deferred for now — chicken-and-egg problem anyway, since Terraform manages the infra that would run MinIO).

## Cluster bootstrap

- k3s via Ansible (or cloud-init script): control-plane + 2 workers joined via token.
- `--disable traefik` at install — using ingress-nginx instead for clearer, more standard k8s learning.
- One-time bootstrap: Helm + ArgoCD installed (via Terraform `helm` provider, or a bash script run once post-VM-creation). This is the one manual seam between the infra layer and the GitOps layer — after this, ArgoCD takes over everything else.

## Networking

- **MetalLB** (L2 mode) — LoadBalancer IPs for bare metal (no cloud LB available). Pool sized to cover all LoadBalancer-type services (adguard DNS, minecraft, terraria, any future game server).
- **ingress-nginx** — HTTP routing for jellyfin/nextcloud/adguard web UIs.
- **Tailscale** — subnet router on one k3s node, advertising the MetalLB IP range. Any device on the tailnet reaches cluster services directly. Solves the no-port-forward / no-domain problem without cost.
  - This replaces wireguard's remote-access role entirely — wireguard was dropped from the stack.
- **Adguard Home** doubles as tailnet DNS (via Tailscale's "override DNS servers" setting) — private DNS names reachable even when away from home.

## Storage

External USB HDD on the Beelink host (Proxmox host, not a VM). Exported via NFS from the host. k3s consumes it dynamically via `nfs-subdir-external-provisioner` — PVCs for jellyfin media, nextcloud files, minecraft/terraria world data.

## GitOps (apps layer)

- "App of apps" pattern: one root ArgoCD Application in `gitops/`, pointing at child Applications per service.
- Auto-sync + prune on every push.
- Sealed-secrets for any credentials (nextcloud DB password, rustdesk relay keys) — never plaintext in the repo.

### Apps, rollout order

1. **Jellyfin** — Helm chart, PVC (NFS) for media.
2. **Nextcloud** — Helm chart + mariadb subchart, PVC (NFS) for files.
3. **Adguard Home** — LoadBalancer IP via MetalLB, port 53 exposed.
4. **Rustdesk-server** — relay/ID components only (hbbs/hbbr), no desktop VM. PVC for ID keys. (Proxmox host is headless — no desktop to remote into; this is purely a self-hosted relay for rustdesk clients used elsewhere.)
5. **Minecraft** — `itzg/minecraft-server` community Helm chart (mature, supports RCON/backups/version selection via env vars). PVC (NFS) for world data. Dedicated MetalLB IP.
6. **Terraria** — plain Deployment + Service + PVC (chart ecosystem less mature here), e.g. `ryshe/terraria-server` image, TCP 7777. PVC (NFS) for world data. Dedicated MetalLB IP.

Game servers are defined the same way as everything else in `gitops/` — spinning up a new instance is copying a Helm values file and letting ArgoCD sync it.

## Backup

Velero for k8s-level resource backup, or Proxmox VM snapshots as a simpler fallback while still learning the stack.

## Explicitly out of scope

- Wireguard — dropped; Tailscale covers the remote-access need without the CGNAT/port-forward problem.
- Public domain + Let's Encrypt via HTTP-01 — not needed; Tailscale handles remote access, DNS-01 could be added later if a public domain is ever bought.
- Desktop VM for rustdesk — not needed; only the relay/ID server is self-hosted.
- Remote Terraform state backend (S3/MinIO) — deferred; local state is sufficient for a solo operator.
