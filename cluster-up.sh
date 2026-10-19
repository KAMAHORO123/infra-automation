#!/usr/bin/env bash
# Start the local RSSB platform simulation after a reboot or `minikube stop`.
#
#   ./cluster-up.sh
#
# Then open http://uat.127.0.0.1.nip.io:8081
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../rssb-pilot-app" && pwd)"

# 1. External shared database (proposal 4.2). It is attached to the cluster
#    network at 192.168.58.50; that attachment survives container restarts.
docker compose -f "$APP_DIR/docker-compose.yml" start postgres

# 2. The 3-node HA cluster. minikube defaults to --leader-elect=false, which is
#    wrong with 3 control planes (all controllers act at once), so force it on.
minikube start -p rssb \
  --extra-config=controller-manager.leader-elect=true \
  --extra-config=scheduler.leader-elect=true

kubectl config use-context rssb
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# 3. After a restart, kube-proxy can come up before the control-plane VIP
#    answers and never write its rules (pods stuck "Unknown", Calico failing to
#    reach 10.96.0.1). Restart it first, then Calico, in that order.
kubectl -n kube-system rollout restart ds/kube-proxy
kubectl -n kube-system rollout status ds/kube-proxy --timeout=600s
kubectl -n kube-system rollout restart ds/calico-node
kubectl -n kube-system rollout status ds/calico-node --timeout=900s

# 4. minikube re-applies addon defaults on every start: restore the MetalLB
#    address pool and expose the ingress controller through it.
kubectl -n metallb-system create configmap config --dry-run=client -o yaml \
  --from-literal=config='address-pools:
- name: default
  protocol: layer2
  addresses:
  - 192.168.58.200-192.168.58.210
' | kubectl apply -f -
kubectl -n metallb-system rollout restart deploy/controller
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=900s

# 5. Reach the ingress from the Mac (cluster IPs live inside Docker's VM).
echo "Ingress on http://uat.127.0.0.1.nip.io:8081  (Ctrl+C to stop)"
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8081:80
