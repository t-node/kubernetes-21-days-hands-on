# Day 15 solution

```bash
# the StatefulSet manages its own PVCs, so remove the Deployment's first
kubectl exec -n devboard deploy/postgres -- \
  pg_dump -U devboard -d devboard --data-only > /tmp/devboard-backup.sql
kubectl delete deployment postgres -n devboard --ignore-not-found
kubectl delete pvc postgres-data -n devboard --ignore-not-found

kubectl apply -f 01-postgres-headless-service.yaml
kubectl apply -f 02-postgres-service.yaml
kubectl apply -f 03-postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n devboard

kubectl rollout restart deployment/backend -n devboard
```

Verify:

```bash
kubectl get statefulset,pods,pvc -n devboard
# pod/postgres-0            <- ordinal name
# pvc/data-postgres-0       <- auto-created by volumeClaimTemplates

kubectl run dns --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup postgres-0.postgres-headless

curl -s http://localhost:30080/api/tasks | head -c 200
```

## Two Services, on purpose

| Service | Type | Who uses it |
|---|---|---|
| `postgres-headless` | `clusterIP: None` | the StatefulSet, for per-pod DNS |
| `postgres` | `ClusterIP` | the backend, load balanced |

The backend's `POSTGRES_HOST` is still `postgres`. **The application did not
change at all** when the database went from Deployment to StatefulSet — which is
the whole promise of the Service abstraction.

## The honest limitation

```bash
kubectl scale statefulset postgres --replicas=3 -n devboard
kubectl wait --for=condition=Ready pod/postgres-2 -n devboard --timeout=180s
for i in 0 1 2; do
  echo -n "postgres-$i: "
  kubectl exec -n devboard postgres-$i -- psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
done
```

Three different answers. **Three independent databases, not a cluster.** The
StatefulSet gave stable names and separate volumes; replication is not its job.
That is the argument for an operator.

```bash
kubectl scale statefulset postgres --replicas=1 -n devboard
kubectl delete pvc data-postgres-1 data-postgres-2 -n devboard --ignore-not-found
```

## The BAD- files

Apply them to see the two `serviceName` failure modes. `BAD-01` is rejected at
admission; `BAD-02` starts happily and breaks DNS silently. The second is the
one that costs you an afternoon.
