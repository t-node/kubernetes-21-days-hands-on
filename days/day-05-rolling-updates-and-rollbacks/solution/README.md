# Day 05 solution

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/devboard-frontend -n devboard

# roll forward
kubectl set image deployment/devboard-frontend frontend=nginx:1.26-alpine -n devboard
kubectl annotate deployment/devboard-frontend -n devboard \
  kubernetes.io/change-cause="upgrade to 1.26" --overwrite

kubectl rollout history deployment/devboard-frontend -n devboard
kubectl rollout undo    deployment/devboard-frontend -n devboard
```

Canary experiment:

```bash
kubectl apply -f canary-stable.yaml -f canary-canary.yaml
kubectl get pods -n devboard -l app=canary-demo --show-labels
kubectl delete -f canary-stable.yaml -f canary-canary.yaml
```

Note both canary Deployments have *distinct* selectors (`track: stable` vs
`track: canary`) so they never fight over pods, while sharing `app: canary-demo`
so a single Service selects both. Getting that split right is the trick.
