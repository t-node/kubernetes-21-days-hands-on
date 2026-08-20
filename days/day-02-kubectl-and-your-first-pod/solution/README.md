# Day 02 solution

- `pod.yaml` - the single-container nginx Pod.
- `sidecar-pod.yaml` - two containers sharing an `emptyDir` volume.

```bash
kubectl apply -f pod.yaml
kubectl apply -f sidecar-pod.yaml

kubectl get pods
kubectl logs web-with-sidecar -c reader --tail=5

kubectl delete -f pod.yaml -f sidecar-pod.yaml
```

Note `emptyDir: {}` in the sidecar manifest. The empty braces are required -
`emptyDir:` alone is a null value and the manifest is rejected. This trips
people up constantly.
