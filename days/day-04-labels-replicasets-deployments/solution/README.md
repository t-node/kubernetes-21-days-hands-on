# Day 04 solution

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/devboard-frontend -n devboard
kubectl get deploy,rs,pods -n devboard
```

The self-healing proof:

```bash
kubectl delete pod -n devboard -l app=devboard-frontend --wait=false
kubectl get pods -n devboard -w      # replacements within seconds
```

Keep this Deployment - Day 05 rolls it forward and back.

`replicaset.yaml` is for the Step 3 experiment only. Delete it afterwards.
