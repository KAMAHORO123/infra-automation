#!/usr/bin/env bash
# Create or start the local RSSB platform simulation (stages 1-3 of proposal 6.2).
#
#   ./cluster-up.sh
#
# Then run ./bootstrap.sh once on a new cluster, and open
# http://uat.127.0.0.1.nip.io:8081
#
# Layout: 1 control plane + 2 workers. RSSB's real cluster has 3 control-plane
# nodes (proposal 6.3); on a 16 GB laptop three API servers + three etcd copies
# left too little for Argo CD and monitoring, so the simulation keeps 3 nodes
# for spreading/draining apps but runs a single control plane.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../rssb-pilot-app" && pwd)"
SUBNET=192.168.58.0/24   # pinned: Git refers to .50 (PostgreSQL) and .200-.210 (MetalLB)
DB_IP=192.168.58.50
DB_CONTAINER=rssb-pilot-app-postgres-1

# 1. The 3 nodes ("VMs").
minikube start -p rssb --nodes 3 --cni=calico --memory=2900 --cpus=2 --subnet="$SUBNET"
kubectl config use-context rssb

# Nodes are Docker containers: set their CPU/memory CAPS (not reservations).
# 3 x 2.9 GB must stay well under Docker's 10 GB, or the VM itself runs out of
# memory and thrashes (load 130+, API timeouts).
for node in rssb rssb-m02 rssb-m03; do
  docker update --cpus 3 --memory 2900m --memory-swap 2900m "$node" > /dev/null
done
kubectl wait --for=condition=Ready nodes --all --timeout=900s

# 2. External shared database (proposal 4.2), on the same network as the nodes.
docker compose -f "$APP_DIR/docker-compose.yml" start postgres
if ! docker inspect "$DB_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -q '"rssb"'; then
  docker network connect --ip "$DB_IP" rssb "$DB_CONTAINER"
fi

# 3. Add-ons (proposal 6.4). minikube re-applies their defaults on every start,
#    so the MetalLB pool and the ingress LoadBalancer are restored each time.
minikube -p rssb addons enable metrics-server
minikube -p rssb addons enable metallb
minikube -p rssb addons enable ingress || true   # slow image pulls can time out its check
kubectl -n metallb-system create configmap config --dry-run=client -o yaml \
  --from-literal=config='address-pools:
- name: default
  protocol: layer2
  addresses:
  - 192.168.58.200-192.168.58.210
' | kubectl apply -f -
kubectl -n metallb-system rollout restart deploy/controller
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"LoadBalancer"}}'

# Keep ordinary workloads off the single control-plane node so the API server
# keeps its CPU/memory (Argo CD + monitoring starved it otherwise). The ingress
# controller is pinned to this node by minikube, so it tolerates the taint.
kubectl taint node rssb node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type json -p \
  '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=1200s

# 4. Reach the ingress from the Mac (cluster IPs live inside Docker's VM).
echo "Ingress on http://uat.127.0.0.1.nip.io:8081  (Ctrl+C to stop)"
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8081:80
