#!/usr/bin/env bash
# Download each image ONCE on this machine, then copy it into every node.
# On a slow line, three nodes pulling the same image in parallel triple the
# traffic; this is the laptop version of a registry mirror (proposal A3).
#
#   ./preload-images.sh                 # the default list below
#   ./preload-images.sh IMAGE [IMAGE…]  # specific images (tag references only:
#                                       # `minikube image load` drops digests)
set -euo pipefail

IMAGES=("$@")
if [ ${#IMAGES[@]} -eq 0 ]; then
  IMAGES=(
    quay.io/argoproj/argocd:v3.5.5
    ghcr.io/dexidp/dex:v2.45.1
    public.ecr.aws/docker/library/redis:8.2.3-alpine
    docker.io/bitnami/sealed-secrets-controller:0.40.0
  )
fi

for image in "${IMAGES[@]}"; do
  echo "==> $image"
  docker pull -q "$image"
  minikube -p rssb image load "$image"
done
