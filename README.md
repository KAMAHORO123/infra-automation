# rssb-infra

How the RSSB platform simulation is built (proposal 6, 7.4). In production this
repo would hold Terraform (VMs) and Ansible (MicroK8s); locally, minikube plays
the three VMs.

| File | Stage (proposal 6.2) | What it does |
|---|---|---|
| `cluster-up.sh` | 1-3 Machines, cluster, add-ons | Creates or starts the 3-node cluster (1 control plane + 2 workers, pinned subnet), attaches external PostgreSQL, restores MetalLB and the ingress LoadBalancer, opens the ingress on :8081 |
| `bootstrap.sh` | 4 Bootstrap | Installs pinned Argo CD and Sealed Secrets, applies our Argo CD settings, then the root application |
| `root-app.yaml` | 4 Bootstrap | The only object applied by hand: Argo CD reads `argocd/` in rssb-config and builds everything else |
| `argocd-cm-patch.yaml` | 4 Bootstrap | Argo CD settings that differ from the defaults (EndpointSlices are managed) |

## Rebuild from nothing

```bash
./cluster-up.sh      # in one terminal (ends by port-forwarding the ingress)
./bootstrap.sh       # in another
```

Then wait for Argo CD: UAT and staging sync automatically; production waits
for a manual Sync. Sealed secrets only decrypt with the cluster key they were
sealed for, so a brand-new cluster needs them re-sealed (or the key restored
from backup).
