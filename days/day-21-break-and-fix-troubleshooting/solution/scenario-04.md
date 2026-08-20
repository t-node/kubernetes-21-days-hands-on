# Scenario 4 — Postgres will not schedule

## Diagnosis

```bash
kubectl get pods -n devboard -l app=postgres
# STATUS: Pending
kubectl describe pod -n devboard -l app=postgres | tail -8
# pod has unbound immediate PersistentVolumeClaims
```

The pod is not the problem — its storage is:

```bash
kubectl get pvc -n devboard
# postgres-fast   Pending
kubectl describe pvc postgres-fast -n devboard | tail -5
# storageclass.storage.k8s.io "fast-ssd" not found
```

```bash
kubectl get storageclass
# standard (default)  rancher.io/local-path
```

## Fix

A PVC's `storageClassName` is immutable, so the PVC must be recreated:

```bash
kubectl delete deployment postgres -n devboard
kubectl delete pvc postgres-fast -n devboard

kubectl apply -f ../../day-14-volumes-pv-pvc/solution/01-postgres-pvc.yaml
kubectl apply -f ../../day-14-volumes-pv-pvc/solution/02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard
```

## The lesson

Two distinct Pending states, and telling them apart is the skill:

- **"waiting for first consumer"** — normal for `WaitForFirstConsumer`, not an
  error.
- **"storageclass not found"** — a real fault that will never resolve.

Also note the cascade: the PVC blocked the pod, the pod blocked the backend's
init container, and the user saw "the app is down". Follow the dependency
chain to its root. (Day 14)
