# Scenario 9 — three faults at once

The realistic one. Multiple things broken, no hints, symptoms that mask each
other. **Time yourself: under 15 minutes is a good result.**

Do not read past this line until you have tried.

---

## Survey first — do not fix anything yet

```bash
kubectl get pods -n devboard
kubectl get endpoints -n devboard
kubectl get events -n devboard --sort-by=.lastTimestamp | tail -20
```

Build the whole picture before touching anything. Fixing one fault while two
remain makes the feedback misleading.

---

## Fault 1 — frontend restarting constantly

```bash
kubectl get pods -n devboard -l app=frontend
# RESTARTS climbing

kubectl describe pod -n devboard -l app=frontend | grep -A4 -i liveness
# Liveness probe failed: Get "http://10.244.1.15:4173/": context deadline exceeded
# Container frontend failed liveness probe, will be restarted
```

```bash
kubectl get deploy frontend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}{"\n"}'
# initialDelaySeconds:1  periodSeconds:1  timeoutSeconds:1  failureThreshold:1
```

Absurdly aggressive: one second to start, one second to answer, one failure to
die. `vite preview` needs a few seconds to boot, so it is killed before it can
ever pass — an infinite restart loop caused purely by probe timing.

```bash
kubectl patch deployment frontend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"frontend","livenessProbe":{"httpGet":{"path":"/","port":4173},"initialDelaySeconds":5,"periodSeconds":10,"timeoutSeconds":3,"failureThreshold":3}}]}}}}'
kubectl rollout status deployment/frontend -n devboard
```

## Fault 2 — backend cannot reach the database

```bash
kubectl logs -n devboard -l app=backend --tail=5
# FATAL ping db: pq: database "devbaord" does not exist
```

The error names the database it asked for. Note the transposition:
`devbaord` / `devboard`.

```bash
kubectl get configmap devboard-config -n devboard -o jsonpath='{.data.POSTGRES_DB}{"\n"}'
# devbaord

kubectl exec -n devboard deploy/postgres -- psql -U devboard -l | grep devboard
# the real database is devboard
```

```bash
kubectl patch configmap devboard-config -n devboard \
  -p '{"data":{"POSTGRES_DB":"devboard"}}'
kubectl rollout restart deployment/backend -n devboard      # env vars need new pods
```

> **Careful:** Postgres also reads `POSTGRES_DB`, but only on *first* init.
> Its data directory already exists, so restarting Postgres would change
> nothing. Only the client was wrong.

## Fault 3 — backend still cannot connect

After fixing fault 2 the backend may *still* fail. Do not assume you
mis-diagnosed; check again:

```bash
kubectl logs -n devboard -l app=backend --tail=5
# dial tcp 10.96.x.x:5432: connect: connection refused
```

**`connection refused`, not `no such host`.** DNS resolved; nothing is listening
at that address. So the Service exists — check where it points:

```bash
kubectl get endpoints postgres -n devboard
# postgres   10.244.1.14:5433        <- port 5433?

kubectl get svc postgres -n devboard \
  -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
# 5433

kubectl get pod postgres-0 -n devboard \
  -o jsonpath='{.spec.containers[0].ports[0].containerPort}{"\n"}'
# 5432
```

The Service forwards to 5433; Postgres listens on 5432.

```bash
kubectl patch svc postgres -n devboard \
  -p '{"spec":{"ports":[{"name":"postgres","port":5432,"targetPort":"postgres"}]}}'
```

Using the **named** port (`targetPort: postgres`) rather than a number makes
this class of mistake much harder to make.

## Verify everything together

```bash
kubectl get pods,endpoints -n devboard
curl -s -o /dev/null -w "UI:    %{http_code}\n" http://localhost:30080
curl -s -o /dev/null -w "tasks: %{http_code}\n" http://localhost:30080/api/tasks
curl -s http://localhost:30080/api/projects | head -c 120; echo
```

---

## The lessons

1. **Survey before fixing.** Three faults were interacting; fixing one in
   isolation gives misleading feedback.

2. **`<none>` vs `no such host` vs `connection refused` are three different
   diagnoses:**

   | Error | Means |
   |---|---|
   | `no such host` | DNS — wrong Service name, or wrong namespace |
   | `connection refused` | DNS fine, wrong **port**, or nothing listening |
   | endpoints `<none>` | selector mismatch, or no Ready pods |
   | timeout / hang | NetworkPolicy, or a ClusterIP with no backends |

3. **Read what the error names.** `database "devbaord" does not exist` contained
   the entire answer.

4. **Config changes need new pods.** `rollout restart` was required for the
   ConfigMap fix and not for the Service fix. Knowing which is which saves
   minutes.
