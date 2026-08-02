# gitops/

ArgoCD Applications + Helm values, one per service. App-of-apps pattern: [`root-app.yaml`](root-app.yaml) points at everything under [`apps/`](apps/), auto-sync + prune on every push.

**Not applied yet** — `root-app.yaml`'s `repoURL` is a placeholder. ArgoCD runs inside the cluster and can only clone from a git remote it can reach; this repo currently only exists on the workstation (`git remote -v` is empty). Push it to GitHub (or wherever), update `repoURL` to match, then apply per the instructions in that file.

See [Phase 5](../docs/implementation-plan.md#phase-5--gitops-app-of-apps) and [Phase 6](../docs/implementation-plan.md#phase-6--app-rollout-in-this-order-per-designmd) in the implementation plan.
