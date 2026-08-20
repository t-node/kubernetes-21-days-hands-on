# Day 06 solution

```bash
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-service.yaml
kubectl rollout status deployment/demo-backend -n devboard

kubectl get svc,endpoints -n devboard
```

Test it (from INSIDE the cluster -- a ClusterIP is not reachable from your laptop):

```bash
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- demo-backend:8080 | head -3
```

The headless and external variants are for the Step 8 and Step 9 experiments:

```bash
kubectl apply -f backend-service-headless.yaml
kubectl run dns --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup demo-backend-headless
```

Compare the answers: the normal Service returns one ClusterIP, the headless one
returns three pod IPs.

Clean up before Day 07 if you want a tidy namespace (Day 07 reuses the
Deployment, so keep that):

```bash
kubectl delete -f backend-service-headless.yaml --ignore-not-found
kubectl delete -f external-db-service.yaml --ignore-not-found
```
