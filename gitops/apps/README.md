# gitops/apps/

One ArgoCD `Application` manifest per service, watched by [`../root-app.yaml`](../root-app.yaml). Empty for now — Phase 6 fills this in, in the rollout order from [`design.md`](../../docs/design.md): jellyfin, nextcloud, adguard, rustdesk-server, minecraft, terraria.
