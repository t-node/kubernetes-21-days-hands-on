# Day 03 solution

```bash
kubectl apply -f namespace.yaml
kubectl apply -f pod-with-ns.yaml
kubectl get pods -n devboard
```

Optional, and instructive together:

```bash
kubectl apply -f limit-range.yaml       # defaults FIRST
kubectl apply -f resource-quota.yaml    # then the cap

kubectl run ok --image=nginx:alpine -n devboard   # accepted, gets defaults
kubectl get pod ok -n devboard -o jsonpath='{.spec.containers[0].resources}'
```

Apply the quota without the LimitRange and the same `kubectl run` is rejected.
That ordering is the whole lesson.

Clean up before Day 04:

```bash
kubectl delete -f resource-quota.yaml --ignore-not-found
kubectl delete -f limit-range.yaml --ignore-not-found
kubectl delete pod ok nginx-explicit -n devboard --ignore-not-found
```

Keep the `devboard` namespace.
