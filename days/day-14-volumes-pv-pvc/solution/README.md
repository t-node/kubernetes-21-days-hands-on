# Day 14 solution

```bash
kubectl apply -f 01-postgres-pvc.yaml
kubectl apply -f 02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard
kubectl get pvc,pv -n devboard
```

The proof:

```bash
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('I will survive', 1);"

kubectl delete pod -n devboard -l app=postgres
kubectl rollout status deployment/postgres -n devboard
sleep 10

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "SELECT id,title FROM tasks WHERE title='I will survive';"
```

## Three things to notice in 02-postgres-deployment-pvc.yaml

1. **`strategy: Recreate`** is now mandatory, not merely tidy. A rolling update
   would try to start a new pod while the old one still holds the RWO volume.
2. **`PGDATA` in a subdirectory** stops being a nicety: a real PV contains
   `lost+found`, so `initdb` into the mount root fails outright.
3. **`replicas: 1`** is load-bearing. Scale to 2 and you get a Multi-Attach
   error, or worse, two postmasters on one data directory.

## Files for the Break It exercises

| File | Demonstrates |
|---|---|
| `03-static-pv.yaml` + `04-static-pvc.yaml` | static binding, and the `Released` state |
| `05-storageclass-retain.yaml` | how to stop `delete pvc` destroying data |
| `06-pvc-bad-storageclass.yaml` | Pending: no such StorageClass |
| `07-pvc-too-big.yaml` | Pending: no PV large enough |

## Still wrong, fixed tomorrow

Postgres is a **Deployment**. Storage alone does not make a workload
stateful-safe: you still have no stable identity, no per-replica volume and no
ordering guarantees. That is Day 15.
