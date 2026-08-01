# Homelab k3s

**Status:** Design complete, not yet implemented (as of 2026-07-30).
**Goal:** Learn Kubernetes hands-on (k3s, Helm, ArgoCD) on a Proxmox mini server, self-hosting jellyfin, nextcloud, adguard, rustdesk-server, minecraft, terraria — fully managed as code via a GitHub repo.

Full design: [`docs/design.md`](design.md)

## Hardware

Beelink SER5 MAX (Ryzen 7 5800H, 24GB RAM, 500GB SSD), running Proxmox VE. External USB HDD for bulk storage (NFS export from host).

## Key decisions

- **3-node k3s cluster** (control-plane + 2 workers) on VMs, even though single physical host — multi-node needed for real k8s scheduling/taints learning.
- **Terraform (`bpg/proxmox` provider) for VM provisioning, ArgoCD for apps** — two-speed GitOps: infra layer applied manually/locally, app layer auto-synced by ArgoCD on every push.
- **No wireguard** — dropped in favor of Tailscale, because ISP blocks port forwarding (CGNAT). Tailscale subnet router advertises the MetalLB IP range instead; no port forward or public domain needed.
- **No domain purchased** — Tailscale covers remote access; DNS-01 challenge could add real TLS later if a domain is bought.
- **Rustdesk = relay/ID server only** (hbbs/hbbr), no desktop VM — Proxmox host is headless, nothing to remote into.
- **Local Terraform state**, not remote backend — solo operator, no locking contention. Revisit only if applying from multiple machines.

## RAM budget (tight, no slack)

control-plane 4GB / worker1 8GB (nextcloud+jellyfin) / worker2 8GB (adguard+rustdesk+minecraft+terraria) / ~4GB Proxmox host overhead = 24GB total.

## Next step

See [`docs/implementation-plan.md`](implementation-plan.md).
