#!/usr/bin/env bash
# Reset a test environment to a clean, known state (proposal: "each environment
# creates its own database, migrations and test data, and can be reset or
# rebuilt from Git").
#
#   ./reset-env.sh uat|staging
#
# Drops and recreates the environment's database, then asks Argo CD to sync the
# backend: its PreSync hook re-runs migrations and loads the seed data.
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  uat|staging) ;;
  production) echo "Refusing: production data is never reset by script." >&2; exit 1 ;;
  *) echo "usage: $0 uat|staging" >&2; exit 1 ;;
esac

DB_CONTAINER=rssb-pilot-app-postgres-1
read -r -p "This DELETES all data in logistics_$ENV. Type the environment name to confirm: " answer
[ "$answer" = "$ENV" ] || { echo "Not confirmed, nothing changed."; exit 1; }

docker exec -i "$DB_CONTAINER" psql -q -v ON_ERROR_STOP=1 -U logistics -d postgres <<SQL
DROP DATABASE IF EXISTS logistics_$ENV WITH (FORCE);
CREATE DATABASE logistics_$ENV OWNER ${ENV}_app;
REVOKE CONNECT ON DATABASE logistics_$ENV FROM PUBLIC;
SQL
echo "logistics_$ENV recreated (empty)."

# Same as pressing SYNC in the Argo CD UI.
kubectl -n argocd patch application "rssb-pilot-backend-$ENV" --type merge \
  -p '{"operation":{"initiatedBy":{"username":"reset-env.sh"},"sync":{"revision":"main"}}}'
echo "Argo CD sync requested: migrations and seed data run as the PreSync hook."
