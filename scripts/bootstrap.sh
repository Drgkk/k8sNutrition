#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K=(kubectl --context=minikube -n pz2)
bash "$ROOT/scripts/check-access.sh" docker
minikube start --profile=minikube --driver=docker --cpus=2 --memory=4096
# Never replace the old combined workload without backing up its database.
LEGACY="$("${K[@]}" get deployment nutrition --ignore-not-found -o name)"
if [[ -n "$LEGACY" ]]; then
  echo 'Old combined Deployment detected. Follow the migration steps in README.md first.' >&2
  exit 1
fi
for addon in ingress metrics-server; do
  minikube -p minikube addons enable "$addon"
done
kubectl --context=minikube -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
kubectl --context=minikube -n kube-system rollout status deployment/metrics-server --timeout=180s
"${K[@]}" apply -f "$ROOT/k8s/namespace.yaml"
for manifest in config secret postgres-pv postgres-pvc postgres-service postgres-deployment java-service ingress; do
  "${K[@]}" apply -f "$ROOT/k8s/$manifest.yaml"
done
kubectl --context=minikube apply -f "$ROOT/k8s/loadbalancer.yaml"
"${K[@]}" rollout status deployment/postgres --timeout=300s
bash "$ROOT/scripts/check-access.sh" cluster
"${K[@]}" get deployments,services,ingress,pvc
echo 'Infrastructure is ready. Run bash scripts/deploy.sh to build and deploy Java.'
echo 'For external access, run minikube -p minikube tunnel in another terminal.'
