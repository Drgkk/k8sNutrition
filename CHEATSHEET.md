# Project presentation: terminal cheat sheet

Run commands selectively, in the order you want to demonstrate features. Startup,
scaling, API writes, Pod deletion, rollback, and Git pushes change the running project.
Commands assume Bash/WSL and the current project structure.

**1. Prepare each presentation terminal**

```bash
cd /home/vadym/projects/pz2

# Always address the correct cluster and application namespace.
k() { kubectl --context=minikube -n pz2 "$@"; }

BASE=http://nutrition.local
api() { curl --silent --show-error -H 'Host: nutrition.local' "$@"; }
```

Repeat these definitions in each new terminal where you need them.

**2. Check Docker, access, and the cluster**

```bash
id
docker info
docker ps
docker images 'nutrition-api'
minikube status -p minikube
kubectl config get-contexts
kubectl --context=minikube get nodes -o wide

bash scripts/check-access.sh docker
bash scripts/check-access.sh cluster
```

`docker ps` shows the Docker-driver Minikube node container. Use `kubectl` to
inspect application Pods and containers inside that node.

For initial setup, or to apply infrastructure changes:

```bash
bash scripts/bootstrap.sh
bash scripts/deploy.sh
```

To resume an existing stopped cluster, without rebuilding the application:

```bash
minikube start -p minikube
k get pods -w
```

For a new application release in an already running, configured cluster:

```bash
bash scripts/deploy.sh
bash scripts/verify.sh
```

`bootstrap.sh` manages the cluster, addons, PostgreSQL, storage, and routing.
`deploy.sh` builds/loads images and updates only the Java Deployments.
Use Ctrl+C to leave a watch or log stream; that does not stop the workloads.

**3. Open external access**

Keep this running in a separate terminal:

```bash
minikube -p minikube tunnel
```

In your presentation terminal:

```bash
kubectl --context=minikube -n ingress-nginx get service nutrition-ingress
getent hosts nutrition.local
```

If necessary, edit `/etc/hosts` and map `nutrition.local` to the actual
LoadBalancer EXTERNAL-IP shown above:

```bash
sudoedit /etc/hosts
```

For example, use `127.0.0.1 nutrition.local` only if that is the external IP.
Windows browser access may also require editing the Windows hosts file.

Fallback if host routing is troublesome: keep this command in another terminal:

```bash
kubectl --context=minikube -n ingress-nginx port-forward service/nutrition-ingress 8080:80
```

Then change the presentation terminal's base URL:

```bash
BASE=http://127.0.0.1:8080
```

The `api` helper always sends `Host: nutrition.local`, so Ingress host routing
works with either base URL. Port-forward exercises the controller and Ingress
rules, while bypassing the external LoadBalancer network route.

**4. Show the architecture and resource consumption**

```bash
# Complete project report, including running containers and CPU/memory.
bash scripts/status.sh

# All Pods throughout the cluster.
kubectl --context=minikube get pods -A -o wide

# Application Pods, their nodes, labels, and readiness.
k get pods -o wide --show-labels
k get pods --field-selector=status.phase=Running -o wide

# Deployments and their ReplicaSets.
k get deployments,replicasets

# ClusterIP Services and Ingress rules.
k get services,ingress
k describe service nutrition-v1
k describe service postgres
k describe ingress nutrition

# Actual ready backends selected by the Java Service.
k get endpointslices -l kubernetes.io/service-name=nutrition-v1 -o wide

# LoadBalancer is in the controller's namespace.
kubectl --context=minikube -n ingress-nginx get services,pods -o wide

# Actual resource consumption (requires metrics-server).
k top pods
k top pods --containers
kubectl --context=minikube top nodes

# Pod configuration, probes, requests/limits, mounts, and events.
k describe pods -l app=nutrition,version=v1
k describe pods -l app=postgres
```

Explain the request path:

```text
Client → LoadBalancer → Ingress controller
       → version-specific Java ClusterIP Service → Java Pod
       → PostgreSQL ClusterIP Service → PostgreSQL Pod → PVC → PV
```

A Pod in phase `Running` can still contain an unready container. Check `READY`
and the readiness probe, not just `STATUS`. The project has three application
Pods by default; addons create additional system Pods.

**5. Show v1, v2, health, and API queries**

```bash
api "$BASE/v1/"
api "$BASE/v2/"
api "$BASE/v1/api/version"
api "$BASE/v2/api/version"
api "$BASE/v1/actuator/health"

api "$BASE/v1/api/nutrition-entries" | python3 -m json.tool
api "$BASE/v1/api/nutrition-entries/search?food=oats&minProtein=10"
api "$BASE/v1/api/nutrition-entries/daily-summary?date=2026-11-15&targetCalories=2500"
```

Both versions expose the same nutrition API and share PostgreSQL. The greeting,
version, and serving Pod are visible at `/v1/` and `/v2/`.

**6. Demonstrate POST, GET, PUT, and DELETE**

Create a request file and a new entry; capture its actual ID:

```bash
cat > /tmp/pz2-demo-entry.json <<'JSON'
{
  "foodName": "Presentation oatmeal",
  "calories": 350.00,
  "proteinGrams": 12.50,
  "carbohydratesGrams": 55.00,
  "fatGrams": 8.00,
  "consumedAt": "2026-11-15T08:30:00"
}
JSON

ENTRY="$(api -X POST "$BASE/v1/api/nutrition-entries" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/pz2-demo-entry.json)"
printf '%s\n' "$ENTRY" | python3 -m json.tool
ENTRY_ID="$(printf '%s' "$ENTRY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

# Read the v1-created entry through v2: the database is shared.
api "$BASE/v2/api/nutrition-entries/$ENTRY_ID" | python3 -m json.tool

# Create a NEW entry with 1.5 times the original nutrition values.
# No JSON body required; the original entry is unchanged.
api -i -X POST "$BASE/v1/api/nutrition-entries/$ENTRY_ID/portion?scale=1.5"

# Update the original entry; PUT expects the complete request body.
python3 - <<'PYTHON'
import json
from pathlib import Path
path = Path('/tmp/pz2-demo-entry.json')
data = json.loads(path.read_text())
data['foodName'] = 'Updated presentation oatmeal'
data['calories'] = 400.00
path.write_text(json.dumps(data))
PYTHON
api -i -X PUT "$BASE/v1/api/nutrition-entries/$ENTRY_ID" \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/pz2-demo-entry.json

# Delete only the original demo entry; the new portion entry remains.
api -i -X DELETE "$BASE/v1/api/nutrition-entries/$ENTRY_ID"

# Expect 404 after deletion.
api -i "$BASE/v1/api/nutrition-entries/$ENTRY_ID"

# Demonstrate input validation: expect 400.
api -i -X POST "$BASE/v1/api/nutrition-entries" \
  -H 'Content-Type: application/json' -d '{}'
```

Create and portion operations return 201, successful PUT returns 200, and
successful DELETE returns 204. Use the portion response's `id` if you also want
to remove that separate entry. Dates above are fixed demonstration values;
change them if you want to show today's summary.

**7. Show PostgreSQL, configuration, and persistent storage**

```bash
k get configmap nutrition-config -o yaml

# Shows Secret key names and sizes, without printing the password.
k describe secret nutrition-db

k get pvc postgres-storage
kubectl --context=minikube get pv pz2-postgres-data
k describe pvc postgres-storage
kubectl --context=minikube describe pv pz2-postgres-data

# Real SQL query in the separate database container.
k exec deployment/postgres -c postgres -- sh -ec \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT id, food_name, calories FROM nutrition_entries ORDER BY id DESC LIMIT 5;"'

# Open an interactive database session; exit with \q.
k exec -it deployment/postgres -c postgres -- sh -ec \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# Inspect the directory behind the PV, inside the Minikube node.
minikube -p minikube ssh -- 'sudo ls -lah /mnt/data'
```

The claim should be `Bound`, with 1 GiB and ReadWriteOnce. The PV's retention
policy is `Retain`. Secret values are base64 encoded, not encrypted by base64.

For an explicit persistence demonstration:

```bash
bash scripts/verify-persistence.sh
bash scripts/verify.sh
```

The persistence script deliberately replaces the database Pod and checks that a
unique SQL marker survives on the same PV. Database-backed requests can briefly
fail during this particular demonstration.

**8. Demonstrate CI/CD and rolling updates**

Terminal A — watch Pod replacements:

```bash
k get pods -w
```

Terminal B — repeatedly check a database-backed endpoint:

```bash
while true; do
  date '+%H:%M:%S'
  curl --silent --show-error --max-time 3 \
    -H 'Host: nutrition.local' -o /dev/null \
    -w 'HTTP %{http_code}\n' "$BASE/v2/api/nutrition-entries"
  sleep 1
done
```

Terminal C — after changing the v2 greeting in `VersionController.java`:

```bash
git status --short
git diff -- app/src/main/java/com/example/nutrition/controller/VersionController.java
git add app/src/main/java/com/example/nutrition/controller/VersionController.java
git commit -m "Demonstrate automatic v2 deployment"
git push
```

Show the new run in GitHub's Actions tab. Pushes to `master` run tests, deploy,
and verify. Initial infrastructure setup is available through **Run workflow →
bootstrap**; it is not triggered by a normal push.

After or during the update:

```bash
k rollout status deployment/nutrition-v1 --timeout=300s
k rollout status deployment/nutrition-v2 --timeout=300s
k get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
k get pods -l app=postgres -o wide
api "$BASE/v2/"
```

Point out the build-specific image tags, the new Java Pod names, and the
unchanged PostgreSQL Pod name/age. Both Java versions are rebuilt on each push;
only Java Deployments are applied by `deploy.sh`. Rolling updates wait for a new
ready Pod before terminating the old one. Do not run a manual deploy at the same
time as Actions.

Optional rollback of Java v2, provided the previous image is still in Minikube:

```bash
k rollout history deployment/nutrition-v2
k rollout undo deployment/nutrition-v2
k rollout status deployment/nutrition-v2 --timeout=300s
api "$BASE/v2/"
```

Rollback changes the application revision, not database schema migrations.
The next CI deployment installs the current repository build again.

**9. Optional scaling and self-healing demonstrations**

Scale Java v1 to two replicas and observe different serving Pod names:

```bash
k scale deployment/nutrition-v1 --replicas=2
k rollout status deployment/nutrition-v1 --timeout=300s
k get pods -l app=nutrition,version=v1 -o wide

for i in {1..10}; do
  api "$BASE/v1/"
  printf '\n'
done

# Restore the normal replica count afterwards.
k scale deployment/nutrition-v1 --replicas=1
```

Requests may reach either ready Pod; exact alternation is not guaranteed.
The next deploy also reapplies the configured replica count of one.
Do not scale the single-instance PostgreSQL Deployment above one replica.

Delete one Java Pod to show that its Deployment creates a replacement:

```bash
JAVA_POD="$(k get pods -l app=nutrition,version=v1 -o jsonpath='{.items[0].metadata.name}')"
k delete pod "$JAVA_POD"
k get pods -l app=nutrition,version=v1 -w
```

This deletion demo can interrupt requests with only one replica. It is different
from a controlled rolling update, which starts the replacement first.

**10. Logs, diagnostics, and verification**

```bash
k logs deployment/nutrition-v1 -c app --tail=50
k logs deployment/nutrition-v2 -c app --tail=50
k logs deployment/postgres -c postgres --tail=50
k logs deployment/nutrition-v2 -c app -f

# Logs from a prior container instance within an existing Pod, if it restarted.
k logs deployment/nutrition-v2 -c app --previous

k get events --sort-by=.metadata.creationTimestamp
k describe pods -l app=nutrition,version=v2
kubectl --context=minikube -n ingress-nginx logs deployment/ingress-nginx-controller --tail=50

# Tests orchestration logic with fake Docker/Kubernetes commands.
python3 -m unittest discover -s tests -p 'test_deployment_scripts.py'

# Full checks through a temporary port-forward, no external tunnel required.
bash scripts/verify.sh

# Full checks through the real external route and hosts mapping instead.
BASE_URL=http://nutrition.local bash scripts/verify.sh
```

`--previous` does not retrieve logs from a Pod that has already been deleted.

**11. Finish the presentation**

Stop foreground watches, port-forwards, and `minikube tunnel` with Ctrl+C.
To stop the cluster while keeping its state and node-local data:

```bash
minikube stop -p minikube
minikube status -p minikube
```

Resume later:

```bash
minikube start -p minikube
k get pods -w
```

A stopped cluster is not restarted by ordinary CI deployments. Do not use
`minikube delete` during the presentation: it removes the cluster and can remove
its node-local database data.

**Suggested short presentation order**

1. `bash scripts/status.sh`: show the architecture, storage, and metrics.
2. Compare `/v1/` and `/v2/`, then read the nutrition entries.
3. Create an entry through v1 and read it through v2.
4. Show the PVC/PV and run a SQL query.
5. Push a greeting change while watching Pods and HTTP responses.
6. Show the successful Actions run and unchanged database Pod.
7. Optionally demonstrate persistence by replacing the database Pod.
