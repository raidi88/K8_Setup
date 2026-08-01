# K8_Setup — Homelab k3s + GitOps

A hands-on Kubernetes/Helm/Terraform learning project: a real 3-node k3s cluster on Proxmox VMs, self-hosting jellyfin, nextcloud, adguard, rustdesk-server, minecraft, and terraria — fully managed as code.

- Design: [`docs/design.md`](docs/design.md)
- Implementation plan / progress checklist: [`docs/implementation-plan.md`](docs/implementation-plan.md)

## Repo structure

```
infra/     # Terraform (bpg/proxmox provider) — VM provisioning, applied manually
gitops/    # ArgoCD Applications + Helm values per app, auto-synced on push
docs/      # Design doc + implementation plan
```

- `infra/` — Terraform, manual local apply only. No CI automation.
- `gitops/` — ArgoCD, auto-sync + prune on every push. App-of-apps pattern.

## Status

Scaffold only. See [`docs/implementation-plan.md`](docs/implementation-plan.md) for the current phase — Phase 1 (Terraform VM provisioning) not yet started.
