# RSSB platform simulation — walkthrough and test guide

This guide explains every part of the simulation of the RSSB *Automated Development
and Test Environment* proposal and shows how to test each one yourself. Every
command was run on the reference setup (MacBook, 16 GB RAM, Docker Desktop with
6 CPUs / 10 GB, minikube with the docker driver).

## 1. The four folders

| Folder (GitHub repo) | Proposal | What it holds |
|---|---|---|
| `rssb-pilot-app` | 4.1 pilot app, 7.2 app repo | NestJS backend + Next.js frontend, Dockerfiles, CI/CD workflows |
| `rssb-config` | 7.3 config repo | Generic Helm chart, values per app and environment, cluster rules, Argo CD definitions, sealed secrets |
| `rssb-infra` | 6, 7.4 infra repo | Cluster start-up, GitOps bootstrap, onboarding tool, reset and preload scripts |
| `rssb-hello-api` | 3 objective 9 | A second app onboarded with one command (proof of the migration tool) |
| `k8s-raw` (local only) | — | The Phase 2 hand-written YAML, kept for learning; replaced by the Helm chart |

Private, never in Git: `~/.rssb-backup/` (sealed-secrets key, Argo CD and Grafana passwords).

## 2. How a change travels (the whole flow)

```
developer ── PR ──▶ develop ──▶ CI: test, Gitleaks, CodeQL, Hadolint, Trivy (PR checks)
                      │ merge
                      ▼
            build amd64+arm64 ─▶ Trivy gate ─▶ push GHCR ─▶ Cosign sign
                      │
                      ▼ rssb-ci-bot commits tag to rssb-config/apps/*/values-uat.yaml
            Argo CD syncs UAT automatically (PreSync: migrations + seed)
                      │ PR develop → qa, merge
                      ▼ no rebuild: same image (git tree hash), tag → values-staging.yaml
            Argo CD syncs staging automatically
                      │ PR qa → main, merge
                      ▼ bot pushes promote/production/<tag>; rssb-config opens a PR
            human reviews + merges (gate 1) ─▶ Argo CD OutOfSync ─▶ human presses Sync (gate 2)
```

## 3. Start everything

```bash
cd ~/Desktop/rssb/rssb-infra
./cluster-up.sh            # terminal 1; ends by port-forwarding the ingress on :8081
./bootstrap.sh             # terminal 2; only on a brand-new cluster
```

Open in a third terminal as needed:

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443          # Argo CD UI
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80  # Grafana
```

| What | URL | Login |
|---|---|---|
| Pilot app, UAT / staging / production | http://uat.127.0.0.1.nip.io:8081 · http://staging… · http://prod… | UAT/staging: `admin@example.com` / `Admin12345!` (production has no demo users) |
| Onboarded app | http://rssb-hello-api-uat.127.0.0.1.nip.io:8081 | — |
| Argo CD | https://localhost:8443 | `~/.rssb-backup/argocd-admin.txt` (admin), `argocd-demo-users.txt` (developer, qa) |
| Grafana | http://localhost:3000 | `~/.rssb-backup/grafana-admin.txt` |

On a slow line, first-time image downloads take long; `./preload-images.sh IMAGE…`
downloads once and copies into every node.

## 4. Test it, part by part

Each test: what to run, and what you should see.

### 4.1 Containers (Phase 1)

```bash
cd ~/Desktop/rssb/rssb-pilot-app && docker compose up -d && open http://localhost:8080
docker compose exec backend id          # uid=1000(node): not root
docker compose exec backend which npm   # nothing: npm removed from the runtime image
```

### 4.2 CI security gates (Phase 5)

Open any PR on GitHub → **Checks** tab. Expected, in stages:
`secret-scan, dockerfile-lint` → `test, sast` → `image-scan ×3` → `all-checks-passed`.

Prove a gate blocks: on a branch, add a fake key such as
`AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` to a file and open a PR.
**secret-scan fails** and the PR cannot merge. Delete the branch afterwards.

Where results live: Actions tab (logs and graph), Security → Code scanning (CodeQL),
`image-scan → Trivy report` step (HIGH findings listed, CRITICAL blocks).

### 4.3 Images and signatures

```bash
docker buildx imagetools inspect ghcr.io/kamahoro123/rssb-pilot-app/backend:tree-42ded8b5d0ed
#   → linux/amd64 and linux/arm64
docker run --rm ghcr.io/sigstore/cosign/cosign:v3.1.3 verify \
  ghcr.io/kamahoro123/rssb-pilot-app/backend:tree-42ded8b5d0ed \
  --certificate-identity-regexp '^https://github.com/KAMAHORO123/rssb-pilot-app/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
#   → "The following checks were performed…": signed by this repo's pipeline
```

### 4.4 Cluster (Phase 2)

```bash
kubectl get nodes                       # rssb (control-plane) + rssb-m02 + rssb-m03, Ready
kubectl top nodes                       # live CPU/RAM (metrics-server)
kubectl get svc -n ingress-nginx        # EXTERNAL-IP 192.168.58.200 (MetalLB)
kubectl get ns -L pod-security.kubernetes.io/enforce   # uat/staging/production: restricted
```

Self-healing: `kubectl -n uat delete pod -l app.kubernetes.io/name=rssb-pilot-backend`
→ a new pod is Running within seconds.

### 4.5 Helm chart (Phase 3)

```bash
cd ~/Desktop/rssb/rssb-config
helm lint --strict charts/generic-app -f apps/rssb-pilot-backend/values.yaml -f apps/rssb-pilot-backend/values-prod.yaml
helm template rssb-pilot-backend charts/generic-app -n production \
  -f apps/rssb-pilot-backend/values.yaml -f apps/rssb-pilot-backend/values-prod.yaml | less
```

Compare `values-uat.yaml` and `values-prod.yaml`: only replicas/autoscaling, PDB,
hostname, seed and tag differ. One chart, three environments, no copy-paste.

### 4.6 Argo CD (Phase 4)

In the UI: 14 application tiles. Click `rssb-pilot-backend-uat` → tree of
Deployment → ReplicaSet → Pods, plus Service, Ingress, ConfigMap, migration Job.

- **Drift and self-heal**: `kubectl -n uat scale deploy rssb-pilot-backend --replicas=3`
  → OutOfSync within seconds, back to 1 within ~15 s.
- **Production gate**: `*-prod` apps never sync on their own. Change a prod value only
  through a reviewed PR, then press **SYNC** in the UI.
- **Rollback**: `git revert` the commit that changed a tag in rssb-config (through a PR);
  Argo CD restores the previous version.
- **Permissions**: log in as `developer` → SYNC works on `*-uat`, is denied on `*-staging`
  and `*-prod`. As `qa` → only `*-staging`.

### 4.7 End-to-end delivery (CI → GitOps)

1. Change something small in rssb-pilot-app on a `feature/*` branch, PR into `develop`, merge.
2. Watch Actions → **Build and publish**: build ×6, publish ×3, promote.
3. rssb-config history: `rssb-ci-bot | Deploy tree-… to uat`.
4. Argo CD: `*-uat` apps sync to the new tag; staging and production do not move.
5. PR `develop → qa`: the pipeline **skips build** (same tree) and moves only staging.
6. PR `qa → main`: a PR appears in rssb-config **opened by github-actions**; approve,
   merge, then SYNC the `*-prod` apps.

### 4.8 Security inside the cluster (Phase 6)

```bash
# Network policies: only the backend may reach the database; nothing crosses environments.
kubectl -n uat exec deploy/rssb-pilot-frontend -- node -e \
 "require('net').connect({host:'192.168.58.50',port:5432,timeout:3000}).on('timeout',()=>{console.log('BLOCKED');process.exit()}).on('connect',()=>{console.log('OPEN');process.exit()})"
#   frontend → BLOCKED;  repeat with deploy/rssb-pilot-backend → OPEN

# RBAC: ask Kubernetes without doing anything.
kubectl auth can-i get pods -n production --as alice --as-group rssb:developers   # no
kubectl auth can-i get pods -n uat        --as alice --as-group rssb:developers   # yes
kubectl auth can-i get secrets -n uat     --as alice --as-group rssb:developers   # no

# Quotas
kubectl -n production describe resourcequota environment-quota

# Sealed secrets: encrypted in Git, decrypted only in the cluster.
cat ~/Desktop/rssb/rssb-config/sealed-secrets/backend-secrets-uat.yaml   # unreadable
kubectl get sealedsecrets -A                                              # SYNCED True
```

### 4.9 Scaling (Phase 7)

```bash
# Load the production backend for 2 minutes and watch the HPA add copies (2 → 4).
H=http://prod.127.0.0.1.nip.io:8081/api/health
( end=$((SECONDS+120)); seq 1 30 | xargs -P 30 -I{} sh -c "while [ \$SECONDS -lt $end ]; do curl -s -o /dev/null $H; done" ) &
watch kubectl -n production get hpa,pods
# VPA advice (never applied automatically):
kubectl -n production describe vpa rssb-pilot-backend | sed -n '/Recommendation/,$p'
```

### 4.10 Monitoring and alerts (Phase 8)

Grafana → Dashboards → **Kubernetes / Compute Resources / Namespace (Pods)** →
namespace `production`: CPU and memory per pod, the HPA load test is visible.
Also: *Compute Resources / Cluster*, *Node Exporter / Nodes*, *API server*.

Alerts from Argo CD (deployed, sync failed, degraded):

```bash
kubectl -n argocd logs deploy/notification-receiver --tail=50
```

Point `service.webhook.rssb-alerts.url` in `argocd-notifications-cm-patch.yaml` at
RSSB's channel once it is confirmed.

### 4.11 Per-environment data and reset (Phase 9)

```bash
docker exec rssb-pilot-app-postgres-1 psql -U logistics -l | grep logistics_
#   logistics_uat / _staging / _production, each owned by its own user
./reset-env.sh staging      # type "staging" to confirm; DB recreated, migrations + seed re-run
./reset-env.sh production   # refused
```

### 4.12 Onboarding another app (Phase 10)

```bash
cd ~/Desktop/rssb
./rssb-infra/onboard/onboard-app.sh --name orders-api --type nestjs \
  --app-dir ~/code/orders-api --config-dir ./rssb-config
```

Then: commit the app repo on a branch, add the `CONFIG_REPO_DEPLOY_KEY` secret, PR the
config folder, PR the app into develop. `rssb-hello-api` went through exactly this.

### 4.13 Disaster recovery

The cluster was deleted and rebuilt from Git on 2026-10-19:

```bash
minikube delete -p rssb          # everything inside the cluster is gone
./cluster-up.sh && ./bootstrap.sh
```

Argo CD recreated every environment from rssb-config; the restored sealing key
(`~/.rssb-backup/sealed-secrets-key.yaml`) decrypted all secrets; the external
database kept all data. Production waited for a manual Sync, as designed.

## 5. Differences from the real RSSB platform

| Real RSSB (proposal) | Simulation | Why |
|---|---|---|
| 3 MicroK8s VMs, all control plane (6.3) | minikube: 1 control plane + 2 workers | Three API servers + etcd exhausted 16 GB laptop with Argo CD and monitoring |
| Terraform + Ansible | `cluster-up.sh` + `bootstrap.sh` | Same stages, laptop tooling |
| Internal DNS names, TLS (cert-manager) | `*.127.0.0.1.nip.io`, plain HTTP, port-forward | No real DNS/certificates on a laptop |
| SSO for Argo CD (8.2) | Local accounts, Dex off | Identity provider to be confirmed |
| Alert channel (8.2) | Webhook receiver in the cluster | Channel to be confirmed |
| Registry mirror (A3) | `preload-images.sh` | Slow internet link |
| External PostgreSQL servers | Postgres container on the cluster network (192.168.58.50) | Same pattern: outside the cluster, one DB + user per environment |

## 6. Problems met, and what they teach

| Problem | Lesson |
|---|---|
| Upstream CI green, Dockerfiles broken | CI must build the artifact you deploy |
| `.dockerignore` at repo root ignored | It is read from the build context root |
| Login 500: `JWT_ISSUER` missing | Every env var the app reads belongs in the deployment config |
| `node` user rejected by `runAsNonRoot` | Use numeric UIDs |
| 4 CRITICAL CVEs, 3 sources | Fix base image, remove runtime tools, update deps; accept with expiry only when unreachable |
| `digests-backend-*` matched migrator | Glob patterns need unambiguous separators |
| minikube HA without leader election | HA control planes need leader election |
| Helm merged two probe handlers | Values files merge maps; defaults must not collide |
| PreSync Job needed a ConfigMap from Sync | Hooks run before the main phase; depend only on earlier waves |
| Argo CD ignored EndpointSlices | Know your tool's default exclusions; "Synced" can hide skipped objects |
| Bot PR never got `validate` | GITHUB_TOKEN events do not trigger workflows; checks belong to commits |
| Grafana random password = permanent drift | Never let a chart generate secrets under GitOps |
| Grafana OOMKilled at 256 Mi | Measure, then size limits |
| API server starved | Keep workloads off the control plane; size for the real load |
| Edited `bootstrap.sh` while it ran | Bash reads scripts incrementally; never edit a running script |
