# Day 09 solution

Baseline:

```bash
kubectl apply -f 01-configmap.yaml
kubectl apply -f 02-backend-deployment.yaml
```

The main exercise -- run the frontend against a backend Service whose name the
image does not know:

```bash
kubectl apply -f 03-backend-service-renamed.yaml
kubectl apply -f 04-vite-config-configmap.yaml
kubectl apply -f 05-frontend-deployment-mounted.yaml
kubectl rollout status deployment/frontend -n devboard

kubectl exec -n devboard deploy/frontend -- cat /app/vite.config.js
```

The env-vs-file demonstration:

```bash
kubectl apply -f 06-demo-envtest.yaml
kubectl logs -f envtest -n devboard          # watch both values

# in another terminal:
kubectl patch configmap devboard-config -n devboard \
  -p '{"data":{"DEMO_SETTING":"changed"}}'
```

Within about a minute the log shows `file=changed` while `env=original` stays
that way forever. Then:

```bash
kubectl delete pod envtest -n devboard
```

## Restore standard naming before Day 10

Day 10 onward assumes the backend Service is called `backend`:

```bash
kubectl delete -f 03-backend-service-renamed.yaml --ignore-not-found
kubectl apply -f ../../day-08-build-and-load-app-images/solution/02-backend-service.yaml
kubectl apply -f ../../day-08-build-and-load-app-images/solution/03-frontend-deployment.yaml
```
