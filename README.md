# infra-automation

Stand-in for RSSB's **`infra-automation`** repository (plan v3.2 §5.3, D23): how the
cluster itself is built. In RSSB this is the Ansible MicroK8s role (inventories
`pdc`/`dr`); in this laptop simulation minikube plays the three VMs.

| File | Stage (plan 6.2) | What it does |
|---|---|---|
| `cluster-up.sh` | 1–3: machines, cluster, add-ons | Creates/starts the 3-node cluster (1 control plane + 2 workers, pinned subnet), attaches the external PostgreSQL, restores MetalLB and the ingress, opens the ingress on :8081 |
| `reset-env.sh uat\|staging` | operations | Recreates an environment's database; Argo CD re-runs migrations and seed. Refuses production |
| `preload-images.sh` | operations | Downloads images once and copies them into every node (slow links; laptop stand-in for a registry mirror) |
| `docs/WALKTHROUGH.md` | — | **Start here**: how everything fits together and how to demonstrate it |

The other two platform repos:

| Repo | Holds |
|---|---|
| [platform-gitops](https://github.com/KAMAHORO123/platform-gitops) | `bootstrap/` (Argo CD, Sealed Secrets, root app), `apps/*/base + envs/*`, `infra/` |
| [rssb-devops](https://github.com/KAMAHORO123/rssb-devops) | Reusable workflows (security gates, build once, digest promotion), onboarding kit |

## Rebuild from nothing

```bash
./cluster-up.sh                                   # this repo
../platform-gitops/bootstrap/bootstrap.sh         # once per new cluster
```
