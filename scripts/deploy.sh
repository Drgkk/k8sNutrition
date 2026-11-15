#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K=(kubectl --context=minikube -n pz2)
# A unique tag identifies the commit and build, including local uncommitted work.
COMMIT="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse --short=12 HEAD)}"
BUILD_ID="$COMMIT-${GITHUB_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}-${GITHUB_RUN_ATTEMPT:-$RANDOM}"
[[ "$BUILD_ID" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,119}$ ]] || { echo 'Invalid build identifier' >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
bash "$ROOT/scripts/check-access.sh" docker
minikube start --profile=minikube --driver=docker --cpus=2 --memory=4096
# The previous combined Pod owns a different PVC. Never delete its data silently.
LEGACY="$("${K[@]}" get deployment nutrition --ignore-not-found -o name)"
if [[ -n "$LEGACY" ]]; then
  echo 'Old combined Deployment detected. Follow the migration steps in README.md to back up the database and remove old workloads first.' >&2
  exit 1
fi
for addon in ingress metrics-server; do
  minikube -p minikube addons enable "$addon"
done
kubectl --context=minikube -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
kubectl --context=minikube -n kube-system rollout status deployment/metrics-server --timeout=180s
for version in v1 v2; do
  docker build --build-arg "APP_VERSION=$version" -t "nutrition-api:$version-$BUILD_ID" "$ROOT"
  minikube --profile=minikube image load "nutrition-api:$version-$BUILD_ID" --daemon=true --overwrite=true
done
# Install DB first so API startup does not race database initialization.
"${K[@]}" apply -f "$ROOT/k8s/namespace.yaml"
for manifest in config secret postgres-pv postgres-pvc postgres-service postgres-deployment; do
  "${K[@]}" apply -f "$ROOT/k8s/$manifest.yaml"
done
"${K[@]}" rollout status deployment/postgres --timeout=300s
# Render into a temporary file so the repository keeps its reusable base tags.
# Apply only the final images, avoiding an intermediate rollout to v1/v2 tags.
kubectl --context=minikube kustomize "$ROOT/k8s" | sed \
  -e "s|image: nutrition-api:v1$|image: nutrition-api:v1-$BUILD_ID|" \
  -e "s|image: nutrition-api:v2$|image: nutrition-api:v2-$BUILD_ID|" \
  > "$WORK/deployment.yaml"
kubectl --context=minikube apply -f "$WORK/deployment.yaml"
kubectl --context=minikube apply -f "$ROOT/k8s/loadbalancer.yaml"
bash "$ROOT/scripts/check-access.sh" cluster
# Changing the image tag triggers the Java rollout; unchanged DB Pods stay running.
echo "Deploying Java build: $BUILD_ID"
for version in v1 v2; do
  "${K[@]}" rollout status "deployment/nutrition-$version" --timeout=300s
done
echo 'Waiting for initial resource metrics...'
for attempt in {1..24}; do
  if "${K[@]}" top pods --containers >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 24 ]] || { echo 'Metrics unavailable; check metrics-server in kube-system.' >&2; exit 1; }
  sleep 5
done
bash "$ROOT/scripts/status.sh"
echo 'Run minikube -p minikube tunnel in another terminal.'
echo 'Then map the nutrition-ingress EXTERNAL-IP to nutrition.local in /etc/hosts.'
echo 'Try http://nutrition.local/v1/ and http://nutrition.local/v2/'
