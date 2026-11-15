#!/usr/bin/env bash
set -Eeuo pipefail
K=(kubectl --context=minikube -n pz2)
for tool in kubectl curl python3; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for deployment in postgres nutrition-v1 nutrition-v2; do
  "${K[@]}" rollout status "deployment/$deployment" --timeout=300s
done
"${K[@]}" get pods -o wide
[[ "$("${K[@]}" get pvc postgres-storage -o jsonpath='{.status.phase}')" == Bound ]]
[[ "$("${K[@]}" get pvc postgres-storage -o jsonpath='{.spec.volumeName}')" == pz2-postgres-data ]]
[[ "$(kubectl --context=minikube get pv pz2-postgres-data -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}')" == pz2/postgres-storage ]]
echo 'Database query:'
"${K[@]}" exec deployment/postgres -c postgres -- sh -ec 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM nutrition_entries;"'
WORK="$(mktemp -d)"
FORWARD_PID=''
cleanup() {
  if [[ -n "$FORWARD_PID" ]]; then
    kill "$FORWARD_PID" 2>/dev/null || true
    wait "$FORWARD_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# By default test through the actual controller behind the LoadBalancer Service
# using a local transport. BASE_URL tests external tunnel/DNS routing instead.
BASE_URL="${BASE_URL:-}"
if [[ -z "$BASE_URL" ]]; then
  PORT="${VERIFY_PORT:-18080}"
  kubectl --context=minikube -n ingress-nginx port-forward --address=127.0.0.1 service/nutrition-ingress "$PORT:80" >"$WORK/forward.log" 2>&1 &
  FORWARD_PID=$!
  for attempt in {1..30}; do
    if grep -q 'Forwarding from' "$WORK/forward.log"; then break; fi
    if ! kill -0 "$FORWARD_PID" 2>/dev/null || [[ "$attempt" == 30 ]]; then cat "$WORK/forward.log" >&2; exit 1; fi
    sleep 1
  done
  BASE_URL="http://127.0.0.1:$PORT"
  echo 'Testing Ingress via port-forward of its LoadBalancer Service; external tunnel/DNS routing is not tested.'
fi
for version in v1 v2; do
  echo "Ingress /$version -> matching Java Service -> Java Pod:"
  curl --fail --silent --show-error --max-time 20 -H 'Host: nutrition.local' "${BASE_URL%/}/$version/" > "$WORK/version.json"
  cat "$WORK/version.json"; echo
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"] == sys.argv[2]; assert d["pod"].startswith("nutrition-"+sys.argv[2]+"-")' "$WORK/version.json" "$version"
  # Check both exact-prefix and nested-path rewrites.
  curl --fail --silent --show-error --max-time 20 -H 'Host: nutrition.local' "${BASE_URL%/}/$version" > "$WORK/exact.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["version"] == sys.argv[2]' "$WORK/exact.json" "$version"
  curl --fail --silent --show-error --max-time 20 -H 'Host: nutrition.local' "${BASE_URL%/}/$version/actuator/health" > "$WORK/health.json"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "UP"' "$WORK/health.json"
  curl --fail --silent --show-error --max-time 20 -H 'Host: nutrition.local' "${BASE_URL%/}/$version/api/nutrition-entries" > "$WORK/entries.json"
  python3 -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])),list)' "$WORK/entries.json"
done
echo 'Both versions, prefix stripping, database connectivity and PV/PVC binding verified.'
