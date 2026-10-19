#!/usr/bin/env bash
# Stage 4 of the platform foundation (proposal 6.2): install the GitOps agent
# and secret decryption, then hand control to Git. After this script, nothing
# is deployed by hand: Argo CD applies whatever the config repo says.
#
#   ./bootstrap.sh
set -euo pipefail

ARGOCD_VERSION=v3.5.5          # pinned (proposal 8.2)
SEALED_SECRETS_VERSION=v0.40.0 # pinned

# 1. Argo CD in its own namespace. Server-side apply: its CRDs are too large
#    for the client-side "last-applied" annotation.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# 2. Restore the sealing key BEFORE the controller starts, so it reuses it and
#    every SealedSecret already in Git still decrypts. Without the backup a new
#    cluster generates a new key and all secrets must be re-sealed.
#    The backup lives outside Git: ~/.rssb-backup/sealed-secrets-key.yaml
KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-$HOME/.rssb-backup/sealed-secrets-key.yaml}"
if [ -f "$KEY_BACKUP" ]; then
  kubectl apply -f "$KEY_BACKUP"
else
  echo "No sealing key backup at $KEY_BACKUP: secrets in Git will need re-sealing." >&2
fi

#    Sealed Secrets controller: decrypts SealedSecrets committed to Git into
#    normal Secrets, using a private key that never leaves the cluster.
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

# Our settings on top of the defaults (see argocd-*-patch.yaml): managed
# EndpointSlices, demo accounts, and who may sync which environment.
kubectl -n argocd patch configmap argocd-cm --patch-file "$(dirname "$0")/argocd-cm-patch.yaml"
kubectl -n argocd patch configmap argocd-rbac-cm --patch-file "$(dirname "$0")/argocd-rbac-cm-patch.yaml"
kubectl -n argocd patch configmap argocd-notifications-cm --patch-file "$(dirname "$0")/argocd-notifications-cm-patch.yaml"
kubectl -n argocd rollout restart statefulset/argocd-application-controller

# Demo account passwords: generated once, bcrypt-hashed into Argo CD's own
# secret, plain text only in the private backup folder (never in Git).
USERS_FILE="$HOME/.rssb-backup/argocd-demo-users.txt"
mkdir -p "$(dirname "$USERS_FILE")" && chmod 700 "$(dirname "$USERS_FILE")"
[ -f "$USERS_FILE" ] || for u in developer qa; do echo "$u $(openssl rand -hex 8)"; done > "$USERS_FILE"
chmod 600 "$USERS_FILE"
while read -r user pass; do
  hash=$(htpasswd -nbBC 10 "" "$pass" | tr -d ':\n')
  kubectl -n argocd patch secret argocd-secret --type merge -p \
    "{\"stringData\":{\"accounts.$user.password\":\"$hash\",\"accounts.$user.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
done < "$USERS_FILE"

kubectl -n argocd rollout status deploy/argocd-server --timeout=1800s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=1800s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=1800s
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=1800s

# 3. The root application ("app of apps"): Argo CD reads argocd/ in the config
#    repo, which in turn defines everything else.
kubectl apply -f "$(dirname "$0")/root-app.yaml"
