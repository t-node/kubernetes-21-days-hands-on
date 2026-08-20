# Day 10 solution

```bash
kubectl apply -f ../../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f 01-secret.yaml
kubectl apply -f 02-backend-deployment.yaml
```

See the composed DSN without needing Postgres:

```bash
kubectl apply -f 03-dsn-demo-pod.yaml
kubectl wait --for=condition=Ready pod/dsn-demo -n devboard --timeout=60s
kubectl logs dsn-demo -n devboard
kubectl delete pod dsn-demo -n devboard
```

Expected:

```
POSTGRES_URL=postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable
```

The password came from the Secret; every other component came from the
ConfigMap; neither duplicates the other.

## The three files worth diffing

| File | Shows |
|---|---|
| `02-backend-deployment.yaml` | the `$(VAR)` composition -- today's main idea |
| `03-dsn-demo-pod-broken.yaml` | what ONE typo does: `$(FOO)` left literal, silently |
| `04-backend-deployment-secret-volume.yaml` | the same Secret as a tmpfs file mount |

Compare `02-backend-deployment.yaml` with Day 09's
`02-backend-deployment.yaml`, where `POSTGRES_URL` was a hardcoded string
containing the password. That diff is the lesson.

The backend still CrashLoops -- there is no Postgres until Day 11.
