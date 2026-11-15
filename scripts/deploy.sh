#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K=(kubectl --context=minikube -n pz2)
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
  docker build --build-arg "APP_VERSION=$version" -t "nutrition-api:$version" "$ROOT"
  minikube --profile=minikube image load "nutrition-api:$version" --daemon=true --overwrite=true
done
# Install DB first so API startup does not race database initialization.
"${K[@]}" apply -f "$ROOT/k8s/namespace.yaml"
for manifest in config secret postgres-pv postgres-pvc postgres-service postgres-deployment; do
  "${K[@]}" apply -f "$ROOT/k8s/$manifest.yaml"
done
"${K[@]}" rollout restart deployment/postgres
"${K[@]}" rollout status deployment/postgres --timeout=300s
kubectl --context=minikube apply -k "$ROOT/k8s"
kubectl --context=minikube apply -f "$ROOT/k8s/loadbalancer.yaml"
bash "$ROOT/scripts/check-access.sh" cluster
# Reload environment variables from ConfigMap/Secret on repeat deployments.
"${K[@]}" rollout restart deployment/nutrition-v1 deployment/nutrition-v2
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
