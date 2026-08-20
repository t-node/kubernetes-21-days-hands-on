# Day 11 solution

```bash
# prerequisites from Days 09-10
kubectl apply -f ../../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f ../../day-10-secrets/solution/01-secret.yaml
kubectl apply -f ../../day-10-secrets/solution/02-backend-deployment.yaml

kubectl apply -f .
kubectl rollout status deployment/postgres -n devboard

# the backend has been CrashLooping since Day 08 -- give it a nudge
kubectl rollout restart deployment/backend -n devboard
kubectl rollout status  deployment/backend -n devboard
```

Verify:

```bash
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -c "SELECT id,title,status FROM tasks ORDER BY id LIMIT 5;"

curl -s http://localhost:30080/api/tasks | head -c 300
```

Open <http://localhost:30080> -- the Kanban board renders with real data.

## Prefer generating the init ConfigMap

`01-postgres-init-configmap.yaml` is a committed copy so the repo works
standalone. In practice, generate it from the real files so there is one source
of truth:

```bash
kubectl create configmap postgres-init -n devboard \
  --from-file=app/devboard/init/postgres/ --dry-run=client -o yaml | kubectl apply -f -
```

## What is deliberately wrong here

- **`emptyDir`** -- data dies with the pod. Day 14 replaces it with a PVC.
- **`kind: Deployment`** -- no stable identity or ordering. Day 15 replaces it
  with a StatefulSet.

## What is already right, and worth copying into real work

- `PGDATA` pointing at a subdirectory of the mount.
- `pg_isready` as the probe command, with a generous liveness
  `initialDelaySeconds` so a slow initdb is not mistaken for a hang.
- `strategy: Recreate` so two postmasters never coexist.
- Credentials sourced from the same ConfigMap and Secret the backend uses, so
  the two can never disagree.
