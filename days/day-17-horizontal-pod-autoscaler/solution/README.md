# Day 17 solution

```bash
# prerequisites
kubectl top pods -n devboard                       # metrics-server must work
kubectl apply -f ../../day-16-resources-requests-limits-metrics-server/solution/05-backend-with-resources.yaml

kubectl apply -f 01-backend-hpa.yaml
sleep 45
kubectl get hpa -n devboard                        # TARGETS should show a number
```

## The load test

```bash
# terminal 1
watch -n 2 'kubectl get hpa,pods -n devboard -l app=backend'

# terminal 2
kubectl apply -f 02-load-generator.yaml
# ...watch it scale up over 2-3 minutes...
kubectl delete -f 02-load-generator.yaml
# ...and take FIVE MINUTES to scale back down. That is the default
#    scaleDown stabilization window, not a bug.
```

## Files

| File | Purpose |
|---|---|
| `01-backend-hpa.yaml` | the standard CPU-target HPA |
| `02-load-generator.yaml` | 8 pods hammering `backend:8080/tasks` |
| `03-backend-hpa-tuned.yaml` | explicit `behavior`: fast up, slow down |
| `04-load-generator-heavy.yaml` | 24 pods — enough to exhaust the cluster |
| `05-frontend-hpa.yaml` | a second HPA, different target |
| `06-backend-no-replicas.yaml` | **the correct Deployment shape under an HPA** |
| `07-hpa-memory-BAD.yaml` | why memory is a poor scaling signal |
| `08-hpa-bad-target.yaml` | a DaemonSet has no scale subresource |

## The two things most people get wrong

1. **No CPU request → `<unknown>` forever.** Utilisation is a percentage *of the
   request*. No request, no denominator, no scaling — and no error in
   `kubectl get hpa`. Only `kubectl describe hpa` tells you.

2. **`replicas` in the manifest fights the HPA.** Use
   `06-backend-no-replicas.yaml` as the reference shape.
