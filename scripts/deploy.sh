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
# Routine releases require an existing cluster; they never start Minikube.
if ! bash "$ROOT/scripts/check-access.sh" cluster; then
  echo 'Cluster access failed. Start the existing cluster with minikube start -p minikube, or run bash scripts/bootstrap.sh for initial setup.' >&2
  exit 1
fi
if ! "${K[@]}" get deployment/postgres configmap/nutrition-config secret/nutrition-db pvc/postgres-storage >/dev/null; then
  echo 'Infrastructure is missing. Run bash scripts/bootstrap.sh first.' >&2
  exit 1
fi
"${K[@]}" rollout status deployment/postgres --timeout=300s
for version in v1 v2; do
  docker build --build-arg "APP_VERSION=$version" -t "nutrition-api:$version-$BUILD_ID" "$ROOT"
  minikube --profile=minikube image load "nutrition-api:$version-$BUILD_ID" --daemon=true --overwrite=true
done
# Only apply the Java Deployments. Infrastructure belongs to bootstrap.sh.
# Apply final build tags directly, avoiding an intermediate rollout to base tags.
sed \
  -e "s|image: nutrition-api:v1$|image: nutrition-api:v1-$BUILD_ID|" \
  -e "s|image: nutrition-api:v2$|image: nutrition-api:v2-$BUILD_ID|" \
  "$ROOT/k8s/java-deployment.yaml" > "$WORK/deployment.yaml"
"${K[@]}" apply -f "$WORK/deployment.yaml"
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
