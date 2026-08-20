# Scenario 6 — backend restarting constantly, exit 137

## Diagnosis

```bash
kubectl get pods -n devboard -l app=backend
# RESTARTS climbing, STATUS flipping Running / CrashLoopBackOff

kubectl logs -n devboard -l app=backend --previous --tail=20
# little or nothing useful -- it never got far enough to log
```

**When a container dies before producing logs, check memory first:**

```bash
kubectl describe pod -n devboard -l app=backend | grep -A6 "Last State"
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

**137 = 128 + 9 = SIGKILL.** In Kubernetes that is almost always OOM.

```bash
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
# limits memory: 8Mi
```

8Mi is below what the Go runtime needs to start at all.

## Fix

```bash
kubectl patch deployment backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"500m","memory":"128Mi"}}}]}}}}'
kubectl rollout status deployment/backend -n devboard
kubectl top pods -n devboard -l app=backend      # what it actually uses
```

## The lesson

Memory is **incompressible**: exceeding the limit is an instant SIGKILL, with no
grace period and no chance to log. Compare with CPU, which only throttles.

Set memory limits from measurement plus headroom, and remember that
`kubectl logs` cannot help here — the evidence is in `describe`. (Day 16)
