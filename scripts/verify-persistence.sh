#!/usr/bin/env bash
# Deliberately replaces the database Pod; run separately from routine checks.
set -Eeuo pipefail
K=(kubectl --context=minikube -n pz2)
"${K[@]}" rollout status deployment/postgres --timeout=300s
PV_BEFORE="$("${K[@]}" get pvc postgres-storage -o jsonpath='{.spec.volumeName}')"
[[ -n "$PV_BEFORE" ]]
PROOF="pvc-$(date +%s%N)-$RANDOM"
SQL='CREATE TABLE IF NOT EXISTS pz2_storage_proof (token text PRIMARY KEY);'
"${K[@]}" exec deployment/postgres -c postgres -- sh -ec 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$SQL"
"${K[@]}" exec deployment/postgres -c postgres -- sh -ec 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "INSERT INTO pz2_storage_proof VALUES ('$PROOF');"
OLD_POD="$("${K[@]}" get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
"${K[@]}" delete pod "$OLD_POD" --wait=true --timeout=120s
# Wait for a distinct replacement; Deployment status can briefly be stale.
NEW_POD=''
for attempt in {1..60}; do
  NEW_POD="$("${K[@]}" get pods -l app=postgres -o jsonpath='{range .items[*]}{.metadata.name}{end}')"
  if [[ -n "$NEW_POD" && "$OLD_POD" != "$NEW_POD" ]]; then break; fi
  [[ "$attempt" != 60 ]] || { echo 'Database Pod was not replaced' >&2; exit 1; }
  sleep 2
done
"${K[@]}" wait --for=condition=Ready "pod/$NEW_POD" --timeout=300s
"${K[@]}" rollout status deployment/postgres --timeout=300s
[[ "$("${K[@]}" get pvc postgres-storage -o jsonpath='{.spec.volumeName}')" == "$PV_BEFORE" ]]
RESULT="$("${K[@]}" exec deployment/postgres -c postgres -- sh -ec 'psql -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "SELECT token FROM pz2_storage_proof WHERE token='$PROOF';")"
[[ "$RESULT" == "$PROOF" ]]
"${K[@]}" exec deployment/postgres -c postgres -- sh -ec 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "DELETE FROM pz2_storage_proof WHERE token='$PROOF';"
echo "Verified: $OLD_POD replaced by $NEW_POD; data retained on PV $PV_BEFORE."
