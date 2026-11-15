#!/usr/bin/env bash
set -Eeuo pipefail
MODE="${1:-cluster}"
[[ "$MODE" == docker || "$MODE" == cluster ]] || { echo 'Usage: check-access.sh [docker|cluster]' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Run as your regular user, without sudo.' >&2; exit 1; }
for tool in docker minikube kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
id
if [[ -S /var/run/docker.sock ]]; then
  stat -c 'Docker socket: %A %U %G (gid=%g)' /var/run/docker.sock
fi
if ! docker info >/dev/null; then
  echo 'Docker is inaccessible to the current user. Check Docker Desktop WSL integration or native Docker socket group membership; see README.md.' >&2
  exit 1
fi
echo 'Docker daemon accessible without sudo.'
if [[ "$MODE" == cluster ]]; then
  kubectl --context=minikube cluster-info --request-timeout=10s
  for resource in pods deployments.apps services persistentvolumeclaims; do
    kubectl --context=minikube -n pz2 auth can-i get "$resource"
  done
  kubectl --context=minikube auth can-i get persistentvolumes
  echo 'Kubernetes access uses the current user kubeconfig and RBAC, not a Unix socket group.'
fi
