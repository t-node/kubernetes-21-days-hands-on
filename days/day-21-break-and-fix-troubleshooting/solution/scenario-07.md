# Scenario 7 — scaling leaves pods Pending

## Diagnosis

```bash
kubectl get pods -n devboard -l app=backend
# some Running, several Pending

kubectl describe pod -n devboard -l app=backend | grep -A4 "FailedScheduling"
# 0/3 nodes are available: 3 Insufficient cpu.
```

Now the critical check — is the cluster *actually* busy?

```bash
kubectl top nodes
# CPU%: 6%, 2%, 3%     <- nearly idle
```

**Idle nodes, and yet "Insufficient cpu".** That is the signature of the
scheduler counting **requests**, not usage:

```bash
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'
# {"cpu":"900m","memory":"64Mi"}

kubectl describe node devops-worker | grep -A6 "Allocated resources"
```

8 replicas x 900m = 7.2 cores requested, on a cluster that does not have it —
even though the app uses a few millicores.

## Fix

```bash
kubectl patch deployment backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"500m","memory":"128Mi"}}}]}}}}'
kubectl rollout status deployment/backend -n devboard
kubectl scale deployment backend --replicas=2 -n devboard
```

## The lesson

**The scheduler never looks at actual usage.** A node is full when the sum of
requests reaches allocatable, so inflated requests mean you pay for idle nodes
and hit ceilings that do not exist physically.

Same symptom, different causes worth ruling out: an untolerated taint, an
unmatched nodeSelector, required anti-affinity capping replicas at the node
count, or a ResourceQuota. The `describe` message names which. (Days 16, 18)
