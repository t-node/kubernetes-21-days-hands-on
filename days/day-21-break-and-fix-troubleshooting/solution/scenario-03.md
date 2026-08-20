# Scenario 3 — backend CrashLoopBackOff after a config change

## Diagnosis

```bash
kubectl get pods -n devboard -l app=backend
kubectl logs -n devboard -l app=backend --tail=5
kubectl logs -n devboard -l app=backend --previous --tail=5
```

```
[backend] waiting for postgres (29)...
[backend] FATAL ping db: dial tcp: lookup postgres-db ... no such host
```

The error names the host it tried: **`postgres-db`**. Which Service exists?

```bash
kubectl get svc -n devboard
# postgres    ClusterIP ...
```

Where did `postgres-db` come from?

```bash
kubectl get configmap devboard-config -n devboard -o jsonpath='{.data.POSTGRES_HOST}{"\n"}'
# postgres-db
kubectl exec -n devboard deploy/backend -- env | grep POSTGRES_URL 2>/dev/null
```

A Day 12 detail matters here: the init container also uses `POSTGRES_HOST`, so
the pods sit in `Init:0/1` for a while before the app container even runs.

## Fix

```bash
kubectl patch configmap devboard-config -n devboard \
  -p '{"data":{"POSTGRES_HOST":"postgres"}}'

# env vars NEVER live-update -- the pods must be recreated
kubectl rollout restart deployment/backend -n devboard
kubectl rollout status  deployment/backend -n devboard
```

## The lesson

Patching the ConfigMap alone fixes nothing: **environment variables are fixed at
process start**. The `rollout restart` is not optional, it *is* the fix.
(Days 09, 12)
