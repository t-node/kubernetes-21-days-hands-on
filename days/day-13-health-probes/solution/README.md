# Day 13 solution

| File | What it demonstrates |
|---|---|
| `01-backend-probes-exec.yaml` | **the fix** — liveness on `/health`, readiness also checks Postgres |
| `02-liveness-demo.yaml` | liveness failure → container restarted in place |
| `03-readiness-demo.yaml` | readiness failure → removed from endpoints, **no restart** |
| `04-startup-probe-demo.yaml` | a 60-second starter that would otherwise loop forever |
| `05-backend-graceful.yaml` | `preStop` + `terminationGracePeriodSeconds` |
| `06-backend-BAD-liveness.yaml` | **the anti-pattern** — liveness checking the database |
| `OPTIONAL-add-ready-endpoint.md` | the proper fix, in ~10 lines of Go |

```bash
kubectl apply -f 01-backend-probes-exec.yaml
kubectl rollout status deployment/backend -n devboard
```

## The experiment that proves it works

```bash
kubectl scale deployment postgres --replicas=0 -n devboard
sleep 30
kubectl get pods -n devboard -l app=backend \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
kubectl get endpoints backend -n devboard
```

Expected:

```
NAME                      READY   RESTARTS
backend-6c8b9d7f4-abcde   false   0
backend-6c8b9d7f4-fghij   false   0

NAME      ENDPOINTS   AGE
backend   <none>      12m
```

`READY=false` with `RESTARTS=0` is the entire point of the day: the pods left
the load balancer without being restarted, and they will rejoin on their own the
moment Postgres returns.

Then run the same experiment with `06-backend-BAD-liveness.yaml` and watch
`CrashLoopBackOff` instead. Do both — the contrast is what makes it stick.

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
kubectl apply -f 01-backend-probes-exec.yaml
```
