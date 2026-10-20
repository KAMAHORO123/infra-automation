#!/usr/bin/env bash
# Switch the optional monitoring stack (Prometheus + Grafana + Alertmanager) on or off.
# Its definition lives in Git: platform-gitops/bootstrap/optional/monitoring.yaml.
#
#   ./monitoring.sh on     # ~5-10 min until Grafana is ready on a laptop
#   ./monitoring.sh off    # removes everything it installed (Application finalizer)
#   ./monitoring.sh status
#
# Why a switch: on a 16 GB laptop, monitoring plus three environments exhausted the
# Docker VM (load 116+, API timeouts). In RSSB, monitoring is New Relic (plan D20).
set -euo pipefail
APP_FILE="$(cd "$(dirname "$0")/../platform-gitops" && pwd)/bootstrap/optional/monitoring.yaml"

case "${1:-status}" in
  on)
    kubectl apply -f "$APP_FILE"
    echo "Monitoring switched on. Grafana when ready:"
    echo "  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80   # login: ~/.rssb-backup/grafana-admin.txt"
    ;;
  off)
    kubectl -n argocd delete application monitoring --ignore-not-found --wait=true
    echo "Monitoring switched off (its pods are being removed)."
    ;;
  status)
    kubectl -n argocd get application monitoring 2>/dev/null || echo "Monitoring is off."
    ;;
  *) echo "usage: $0 on|off|status" >&2; exit 1 ;;
esac
