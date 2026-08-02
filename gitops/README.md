# gitops/

ArgoCD Applications + Helm values, one per service. App-of-apps pattern: [`root-app.yaml`](root-app.yaml) points at everything under [`apps/`](apps/), auto-sync + prune on every push.

Repo is now pushed to [github.com/raidi88/K8_Setup](https://github.com/raidi88/K8_Setup) (public), so `root-app.yaml` points at a real, reachable remote. `apps/` is still empty though — Phase 6 fills it in, and `root-app.yaml` hasn't been applied to the cluster yet.

See [Phase 5](../docs/implementation-plan.md#phase-5--gitops-app-of-apps) and [Phase 6](../docs/implementation-plan.md#phase-6--app-rollout-in-this-order-per-designmd) in the implementation plan.
