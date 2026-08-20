# Scenario 2 — frontend pods will not start

**Symptom:** `ImagePullBackOff`. The UI is unreachable; the API still works.

## Diagnosis

```bash
kubectl get pods -n devboard -l app=frontend
kubectl describe pod -n devboard -l app=frontend | tail -8
```

```
Failed to pull image "devboard-frontend:latest":
failed to resolve reference "docker.io/library/devboard-frontend:latest"
```

Two faults at once, and you need both:

```bash
kubectl get deploy frontend -n devboard -o jsonpath=\
'{.spec.template.spec.containers[0].image}{"  "}{.spec.template.spec.containers[0].imagePullPolicy}{"\n"}'
# devboard-frontend:latest  Always
```

1. The tag changed to `:latest`, which was never built or `kind load`ed.
2. `imagePullPolicy: Always` sends the kubelet to Docker Hub even for images
   that *are* on the node.

Confirm what the node actually has:

```bash
docker exec devops-worker crictl images | grep devboard
# devboard-frontend  1.0   ...      <- 1.0 is there, latest is not
```

## Fix

```bash
kubectl set image deployment/frontend frontend=devboard-frontend:1.0 -n devboard
kubectl patch deployment frontend -n devboard --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
kubectl rollout status deployment/frontend -n devboard
```

## The lesson

Note the old pods kept serving until you fixed it — `maxUnavailable` protected
you. A broken image is a **stalled rollout**, not an outage. (Days 05, 08)
