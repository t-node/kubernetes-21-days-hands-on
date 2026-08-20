# Day 16 solution

## Install metrics-server (required for Day 17)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kind needs this or the pod never becomes Ready
kubectl patch deployment metrics-server -n kube-system --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl rollout status deployment/metrics-server -n kube-system
sleep 60
kubectl top nodes
```

## Apply sensible resources to the backend

```bash
kubectl apply -f 05-backend-with-resources.yaml
kubectl rollout status deployment/backend -n devboard
kubectl top pods -n devboard
```

**`05-backend-with-resources.yaml` is a prerequisite for Day 17.** A CPU-target
HPA computes utilisation as a percentage of the CPU *request* — with no request
there is no denominator and the HPA reports `<unknown>` forever.

## The demonstration files

| File | Shows |
|---|---|
| `01-qos-demo.yaml` | all three QoS classes, derived from resources |
| `02-oom-demo.yaml` | OOMKilled, exit code 137 |
| `03-cpu-throttle-demo.yaml` | CPU throttling: slow, never killed |
| `04-unschedulable.yaml` | Pending on requests alone, with idle nodes |
| `06-no-resources.yaml` | the BestEffort trap |
| `07-limit-too-low.yaml` | dies before it can log anything |
| `08-memory-hog.yaml` | no limit → node pressure → your pods evicted |
| `patches/metrics-server-patch.yaml` | the `--kubelet-insecure-tls` patch (a patch, **not** a manifest) |

Run `02` and `03` back to back. The contrast — **killed** versus **slowed** — is
the most useful thing on this page.
