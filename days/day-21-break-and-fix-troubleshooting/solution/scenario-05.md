# Scenario 5 — backend Running but never Ready

**Symptom:** pods say `Running`, `READY 0/1`, `RESTARTS 0`. The API returns 502.

## Diagnosis

`RESTARTS 0` is the clue that narrows it instantly: **liveness is passing,
readiness is not.** If liveness were failing, the container would be restarting.

```bash
kubectl get pods -n devboard -l app=backend
kubectl describe pod -n devboard -l app=backend | grep -A4 -i "readiness"
```

```
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 404
```

**404, not connection refused.** The app is listening and answering — it just
does not have that path.

```bash
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}'
# /healthz
```

The Gin router registers `/health`, not `/healthz`. Prove it:

```bash
kubectl exec -n devboard deploy/backend -- wget -qO- http://127.0.0.1:8080/health
# {"service":"backend","status":"ok"}
```

And the downstream effect:

```bash
kubectl get endpoints backend -n devboard      # <none>
```

## Fix

```bash
kubectl patch deployment backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","readinessProbe":{"httpGet":{"path":"/health","port":8080}}}]}}}}'
kubectl rollout status deployment/backend -n devboard
```

## The lesson

**One letter took the whole service offline**, with every pod reporting
`Running` and every log clean. Not-Ready pods are removed from Service
endpoints, so a wrong probe path is a total outage that looks like health.

This is among the most common self-inflicted Kubernetes incidents there is.
(Days 06, 13)
