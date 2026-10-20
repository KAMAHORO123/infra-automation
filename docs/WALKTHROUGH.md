# RSSB platform lab: presentation guide

How to start the lab, what each part is, and a step-by-step live demonstration of
plan v3.2 with every success criterion (S1–S8). Every command and every number below
was run and measured on this lab (MacBook, 16 GB RAM, Docker Desktop 10 GB / 6 CPUs).

---

## 1. The repositories (who owns what)

| Repo | Plan v3.2 name | Holds | Branches |
|---|---|---|---|
| [rssb-pilot-app](https://github.com/KAMAHORO123/rssb-pilot-app) | app repo | NestJS backend + Next.js frontend, Dockerfiles, two ~25-line caller workflows | `develop` → `staging` → `main` |
| [rssb-hello-api](https://github.com/KAMAHORO123/rssb-hello-api) | app repo | Second app, onboarded with one command | same |
| [rssb-devops](https://github.com/KAMAHORO123/rssb-devops) | central DevOps repo | Reusable workflows (security gates, build once, digest promotion), Dockerfile templates, `onboard-app.sh`; released as tags (`v1.1.0`) | `main` + tags |
| [platform-gitops](https://github.com/KAMAHORO123/platform-gitops) | `platform-gitops` | `bootstrap/` (Argo CD, Sealed Secrets, root app), `apps/<app>/base` + `envs/{uat,staging,prod}`, `infra/` | `main` only |
| [infra-automation](https://github.com/KAMAHORO123/infra-automation) | `infra-automation` | Cluster scripts (stand-in for the Ansible MicroK8s role), this guide | `main` only |

```
developer ─PR─▶ rssb-pilot-app ──calls──▶ rssb-devops workflows (gates, build, sign)
                     │ merge                       │ push image          │ commit digest
                     ▼                             ▼                     ▼
               (develop/staging/main)            GHCR            platform-gitops (Git = truth)
                                                   ▲ pull                 ▲ watch
                                                   └──── Argo CD in the cluster ────┘
                                       uat (auto) · staging (auto) · production (manual Sync)
```

**Key idea for the audience:** the app pipeline never touches the cluster. It only
writes one line per image (a digest) into the GitOps repo. Argo CD pulls.

---

## 2. Before the presentation (30 minutes before)

```bash
cd ~/Desktop/rssb/infra-automation
./cluster-up.sh                  # terminal 1: keep open (it is the tunnel to the apps)
```
It ends with `Forwarding from 127.0.0.1:8081`. Then, in a second terminal:

```bash
kubectl get nodes                                    # rssb, rssb-m02, rssb-m03: Ready
kubectl -n argocd get applications                   # all Synced / Healthy
kubectl -n argocd port-forward svc/argocd-server 8443:443        # terminal 3: Argo CD UI
./monitoring.sh on               # ONLY if you will show Grafana; give it 10 minutes
```

| Open | URL | Login |
|---|---|---|
| UAT / staging / production | http://uat.127.0.0.1.nip.io:8081 · `staging.` · `prod.` | UAT & staging: `admin@example.com` / `Admin12345!` (production has no demo users, by design) |
| Argo CD | https://localhost:8443 (accept the certificate warning) | `cat ~/.rssb-backup/argocd-admin.txt` → user `admin`; demo users in `~/.rssb-backup/argocd-demo-users.txt` |
| Grafana (if on) | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` → http://localhost:3000 | `cat ~/.rssb-backup/grafana-admin.txt` |

Argo CD has **no sign-up page** on purpose: accounts are created by the platform team
(`admin`, `developer`, `qa`); at RSSB they would come from SSO.

---

## 3. The live demonstration

Each step: **say** (one sentence), **do**, **show**.

### Step 1 — One cluster, three environments
- **Say:** "Three machines replace dozens of VMs; UAT, staging and production are namespaces on them."
- **Do:** `kubectl get nodes` · `kubectl get pods -n uat -o wide` (NODE column) · `kubectl get ns -L pod-security.kubernetes.io/enforce`
- **Show:** pods spread over nodes; namespaces enforce `restricted` (no root containers).

### Step 2 — Git is the source of truth (Argo CD)
- **Do:** log in to Argo CD as `admin`. Click `rssb-pilot-backend-uat` → the tree: SealedSecret (wave −2) → migration Job (wave −1) → Deployment → Pods.
- **Show:** `rssb-pilot-backend-prod` has no automatic sync: production changes only when a person presses SYNC.
- **Do:** log out, log in as `developer`. Try SYNC on a `*-prod` app → **permission denied**; on `*-uat` → allowed.

### Step 3 — A developer makes a change (S3: security gates)
```bash
cd ~/Desktop/rssb/rssb-pilot-app
git checkout develop && git pull
git checkout -b feature/new-headline
# edit frontend/src/components/landing/landing-hero.tsx, line 24:
#   Shipment operations, simplified.   ->   Shipment operations, by RSSB.
git commit -am "Change landing headline" && git push -u origin feature/new-headline
gh pr create --base develop --title "Change landing headline" --body "Demo change"
```
- **Show:** the PR's **Checks** tab: `secrets` + `dockerfile-lint` → `sast` (Semgrep) + `dependencies` (Trivy fs) + `test` → `image-scan` (Trivy, HIGH/CRITICAL block) → `all-checks-passed`. All run from the central repo, pinned to `@v1.0.1`.

### Step 4 — Merge → UAT updates itself (S1)
- **Do:** merge the PR on GitHub (green button).
- **Show:** Actions → **Delivery**: `build` ×6 (amd64 + arm64), `publish` ×3 (signed), `deploy`.
  Then platform-gitops → Commits: `rssb-ci-bot | Deploy tree-… to uat` changing **only digest lines in `envs/uat`**.
  Then Argo CD: `rssb-pilot-frontend-uat` syncs. Refresh http://uat.127.0.0.1.nip.io:8081 → new headline.
- **Measured:** merge → UAT live in about 6–10 minutes (build ~3 min, image download on a slow line is the rest).

### Step 5 — Promote to staging: same image, no rebuild (S2)
- **Do:** `gh pr create --base staging --head develop --title "Release to staging"`, merge when green.
- **Show:** Delivery on `staging`: **build and publish skipped**, only `deploy`. Compare digests:
  ```bash
  cd ~/Desktop/rssb/platform-gitops && git pull
  grep digest apps/rssb-pilot-frontend/envs/uat/kustomization.yaml apps/rssb-pilot-frontend/envs/staging/kustomization.yaml
  ```
  identical — QA tests the exact bytes UAT saw. **Measured:** 72 s from merge to staging live.

### Step 6 — Production: two human gates (D18 + manual Sync)
- **Do:** `gh pr create --base main --head staging --title "Release to production"`, merge when green.
- **Show:** Actions → Delivery → **Review deployments** → the job waits for the `production` Environment. Click **Approve**.
- **Show:** Argo CD → `*-prod` apps turn **OutOfSync**. Click **SYNC** (with prune) → production updates.
- **Measured:** production rollout ~2 min, **0 failed requests out of 551** during it (2 copies + PodDisruptionBudget).

### Step 7 — Rollback in seconds (S7)
```bash
cd ~/Desktop/rssb/platform-gitops && git pull
git log --oneline -5                       # find "Deploy tree-… to staging"
git checkout -b rollback/demo && git revert --no-edit <that commit>
git push -u origin rollback/demo && gh pr create --base main --title "Rollback staging" --body "git revert"
```
Merge → staging returns to the previous version. **Measured: 47 s** (target < 5 min).

### Step 8 — Zero downtime (S4) and self-healing
- **Measured:** 3 rollouts (release, rollback, roll forward) under continuous load: **4,062 requests, 0 failures**.
- **Do (self-heal):** `kubectl -n uat delete pod -l app.kubernetes.io/name=rssb-pilot-backend` → replaced in seconds.
- **Do (drift):** `kubectl -n uat scale deploy rssb-pilot-backend --replicas=3` → Argo CD sets it back to 1 within ~15 s.

### Step 9 — Security inside the cluster
```bash
# Only the backend may reach the database; the frontend may not:
kubectl -n uat exec deploy/rssb-pilot-frontend -- node -e "require('net').connect({host:'192.168.58.50',port:5432,timeout:3000}).on('timeout',()=>{console.log('BLOCKED');process.exit()}).on('connect',()=>{console.log('OPEN');process.exit()})"
# RBAC, asked without doing anything:
kubectl auth can-i get pods -n production --as alice --as-group rssb:developers    # no
kubectl auth can-i get secrets -n uat     --as alice --as-group rssb:developers    # no
# Secrets are encrypted in Git:
cat ~/Desktop/rssb/platform-gitops/apps/rssb-pilot-backend/envs/uat/backend-secrets.sealed.yaml
```

### Step 10 — Autoscaling (S5)
```bash
H=http://prod.127.0.0.1.nip.io:8081/login
( end=$((SECONDS+120)); seq 1 30 | xargs -P 30 -I{} sh -c "while [ \$SECONDS -lt $end ]; do curl -s -o /dev/null $H; done" ) &
watch kubectl -n production get hpa,pods
```
The frontend HPA adds copies (2 → 4) and removes them ~5 min after the load stops.

### Step 11 — Monitoring and alerts (if switched on)
Grafana → Dashboards → *Kubernetes / Compute Resources / Namespace (Pods)* → `production`.
Alerts from Argo CD: `kubectl -n argocd logs deploy/notification-receiver --tail=30`.

### Step 12 — Onboarding the next app (one command)
```bash
~/Desktop/rssb/rssb-devops/scripts/onboard-app.sh --name orders-api --type nestjs \
  --app-dir ~/code/orders-api --gitops-dir ~/Desktop/rssb/platform-gitops
```
`rssb-hello-api` went through exactly this and runs in all three environments.

---

## 4. Evidence (plan v3.2 success criteria)

| # | Criterion | Result in this lab |
|---|---|---|
| S1 | Merge to develop reaches UAT with no manual step | ✅ every merge in this lab |
| S2 | Staging/prod run the byte-identical UAT image | ✅ same digest in uat, staging, production |
| S3 | Critical CVE or leaked secret blocks the pipeline | ✅ Next 14 CRITICAL RCE blocked; fixed by upgrading to 15.5; 0 fixable HIGH/CRITICAL |
| S4 | Zero-downtime rollout | ✅ 0 / 4,062 requests failed over 3 rollouts; 0 / 551 in production |
| S5 | Scales out and back in | ✅ HPA 2 → 4 under load |
| S6 | Survives losing a node | ✅ node drain under load: 205 / 206 (PodDisruptionBudget and preStop since added) |
| S7 | Rollback < 5 min | ✅ 47 s via `git revert` |
| S8 | Cluster rebuildable from code | ✅ deleted and rebuilt from Git; sealed-secret key restored from backup |

Real problems the gates and drills found (good material for questions):
- Upstream Dockerfiles could never build or start; CI had never built them.
- A **migration Job without its seed tool** blocked a release: wave −1 stopped wave 0 and UAT kept serving.
- **Rate limiting behind the ingress was shared by all users** (60 requests/min for everyone) → fixed with `trust proxy` (plan A7).
- Semgrep found an **nginx h2c-smuggling** risk and a missing **Dependabot cooldown**.

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Browser can't open `*.nip.io:8081` | the tunnel terminal was closed (apps still run) | `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8081:80` |
| `Cannot connect to the Docker daemon` | Docker Desktop not running | `docker desktop start`, then `./cluster-up.sh` |
| Everything slow, API timeouts | laptop memory exhausted | `./monitoring.sh off`; keep Docker at 10 GB and nodes at 2.9 GB |
| New version stuck "Progressing" for minutes | image download on a slow line | wait; check `kubectl get events -A | grep Pull` |
| Production not updating | by design | press SYNC on the `*-prod` apps in Argo CD |

## 6. Lab versus real RSSB

| RSSB (plan v3.2) | This lab |
|---|---|
| 3 MicroK8s VMs, all control plane (one cluster per site for prod, D6) | minikube: 1 control plane + 2 workers on one laptop |
| Ansible role in `infra-automation` | `cluster-up.sh` |
| New Relic (D20) | Prometheus + Grafana, switched on only when shown |
| FortiADC / nginx proxy hosts as the edge, real DNS + TLS (D7, D19) | port-forward tunnel and `*.127.0.0.1.nip.io` |
| SSO for Argo CD | local accounts (`admin`, `developer`, `qa`) |
| PostgreSQL HA on VMs (Patroni) | one Postgres container outside the cluster, one DB + user per environment |
| Yarn + TypeORM apps (A13, A14) | npm + Prisma pilot |
