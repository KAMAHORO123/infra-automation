#!/usr/bin/env bash
# Forward GitHub webhooks for platform-gitops to the local Argo CD, so a push
# syncs in seconds instead of waiting for Argo CD's ~3-minute Git polling.
#
#   ./webhook-relay.sh          # keep running (like the port-forward tunnels)
#
# GitHub cannot reach a laptop (or RSSB's internal Argo CD), so GitHub posts to
# a public smee.io channel and this client pulls the messages and forwards them
# to https://localhost:8443/api/webhook. Argo CD verifies GitHub's signature
# with webhook.github.secret (stored in argocd-secret; copy in ~/.rssb-backup).
# In RSSB: an internal relay or a firewall path to Argo CD (plan story 3.7).
#
# Needs the Argo CD tunnel:  kubectl -n argocd port-forward svc/argocd-server 8443:443
set -euo pipefail

SMEE_URL="$(cat "$HOME/.rssb-backup/smee-url.txt")"

# Argo CD's certificate in the lab is self-signed (valid for "localhost"). Trust
# exactly that certificate for the local hop; TLS verification stays ON for
# everything else, including smee.io. (Never NODE_TLS_REJECT_UNAUTHORIZED=0:
# it would disable verification of the internet connection too.)
CERT="$(mktemp -t argocd-cert)"
echo | openssl s_client -connect localhost:8443 -servername localhost 2>/dev/null | openssl x509 > "$CERT"
export NODE_EXTRA_CA_CERTS="$CERT"
exec npx --yes smee-client@5.0.0 --url "$SMEE_URL" --target https://localhost:8443/api/webhook
