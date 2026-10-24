#!/usr/bin/env bash
# Build the StreamFlix image (linux/amd64 — nodes are x86) and push to ECR.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

REPO=$(terraform -chdir=terraform output -raw ecr_repository_url)
REGISTRY=${REPO%%/*}
TAG=${TAG:-$(date +%Y%m%d-%H%M%S)}

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker buildx build --platform linux/amd64 -t "$REPO:$TAG" -t "$REPO:latest" --push app/

echo "$REPO:$TAG" > .image
echo "Pushed $REPO:$TAG"
