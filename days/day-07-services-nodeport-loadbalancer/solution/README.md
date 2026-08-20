# Day 07 solution

```bash
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service-nodeport.yaml
kubectl rollout status deployment/devboard-frontend -n devboard
```

Open <http://localhost:30080>.

If that fails, work down this list in order:

1. `kubectl get endpoints devboard-frontend -n devboard` -- populated?
2. `kubectl get svc devboard-frontend -n devboard` -- is the nodePort 30080?
3. `docker port devops-control-plane` -- is 30080 published to the host?
4. Is something else on your machine already listening on 30080?

`frontend-service-loadbalancer.yaml` is *meant* to stay `<pending>` on kind.
That is the lesson, not a broken manifest.
