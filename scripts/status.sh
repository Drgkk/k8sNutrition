#!/usr/bin/env bash
set -Eeuo pipefail
K=(kubectl --context=minikube -n pz2)
echo 'All Pods in the cluster:'
kubectl --context=minikube get pods -A -o wide
echo 'Running application Pods:'
"${K[@]}" get pods --field-selector=status.phase=Running -o wide
echo 'Deployments, ReplicaSets, ClusterIP Services, Ingress and PVC:'
"${K[@]}" get deployments,replicasets,services,ingress,pvc
echo 'Static PersistentVolume:'
kubectl --context=minikube get pv pz2-postgres-data
echo 'LoadBalancer exposing the Ingress controller:'
kubectl --context=minikube -n ingress-nginx get service nutrition-ingress
echo 'Running containers: POD / CONTAINER / READY / STARTED AT'
"${K[@]}" get pods -o go-template='{{range .items}}{{$pod := .metadata.name}}{{range .status.containerStatuses}}{{if .state.running}}{{printf "%s\t%s\t%v\t%s\n" $pod .name .ready .state.running.startedAt}}{{end}}{{end}}{{end}}'
echo 'Requests and limits per container:'
"${K[@]}" get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,MEM_REQUEST:.spec.containers[*].resources.requests.memory,CPU_LIMIT:.spec.containers[*].resources.limits.cpu,MEM_LIMIT:.spec.containers[*].resources.limits.memory'
echo 'Actual CPU and memory usage (metrics-server):'
if ! "${K[@]}" top pods; then
  echo 'Metrics unavailable: wait for initial samples and rerun. Check metrics-server in kube-system.' >&2
  exit 1
fi
"${K[@]}" top pods --containers
kubectl --context=minikube top nodes
