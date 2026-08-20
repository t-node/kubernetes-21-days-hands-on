# kubectl Cheat Sheet

Every command used in this course, grouped by what you are trying to do.

Most examples use `-n devboard`. Set it as your default with:

```bash
kubectl config set-context --current --namespace=devboard
```

---

## Setup and context

```bash
kubectl version --client
kubectl cluster-info
kubectl config current-context                  # which cluster am I on?
kubectl config get-contexts
kubectl config use-context kind-devops
kubectl config view --minify | grep namespace

kubectl auth whoami
kubectl auth can-i --list

alias k=kubectl
source <(kubectl completion bash)               # zsh: completion zsh
```

**Check `current-context` before anything destructive.** Running the right
command against the wrong cluster is a real and expensive mistake.

---

## Discovering the API

```bash
kubectl api-resources                           # every kind, with short names
kubectl api-resources --namespaced=false        # cluster-scoped kinds
kubectl api-resources | grep -i deployment      # which apiGroup?
kubectl api-versions

kubectl explain pod
kubectl explain pod.spec.containers
kubectl explain deployment.spec.strategy --recursive
```

`kubectl explain` is offline documentation for the exact version your cluster
runs. It is the most underused command in Kubernetes.

---

## Looking at things

```bash
kubectl get pods
kubectl get pods -o wide                        # node, pod IP
kubectl get pods -A                             # every namespace
kubectl get all -n devboard
kubectl get pods -w                             # watch
kubectl get pods --show-labels
kubectl get pods -l app=backend
kubectl get pods -l 'env in (dev,staging)'
kubectl get pods -l '!version'
kubectl get pods --field-selector=status.phase!=Running
kubectl get pods --sort-by=.metadata.creationTimestamp

kubectl get pod nginx -o yaml
kubectl get pod nginx -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pods -o custom-columns=\
NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,QOS:.status.qosClass

kubectl describe pod nginx                      # READ THE EVENTS AT THE BOTTOM
```

---

## Creating and changing

```bash
kubectl apply -f manifest.yaml
kubectl apply -f directory/                     # alphabetical, NOT recursive
kubectl apply -f directory/ --recursive         # include subdirectories
kubectl apply -k overlays/prod/                 # kustomize
kubectl delete -f manifest.yaml

kubectl apply -f x.yaml --dry-run=client -o yaml    # local validation
kubectl apply -f x.yaml --dry-run=server           # real validation, no write
kubectl diff -f x.yaml                             # what would change?

kubectl edit deployment backend
kubectl patch deployment backend -p '{"spec":{"replicas":3}}'
kubectl patch deployment backend --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"}]'
kubectl set image deployment/backend backend=devboard-backend:2.0
kubectl set env deployment/backend LOG_LEVEL=debug
kubectl scale deployment backend --replicas=5
kubectl label pod nginx tier=web
kubectl label pod nginx tier-                   # trailing dash removes
kubectl annotate deployment/backend kubernetes.io/change-cause="JIRA-123"
```

### Generate YAML instead of writing it from memory

```bash
kubectl run nginx --image=nginx --dry-run=client -o yaml
kubectl create deployment web --image=nginx --dry-run=client -o yaml
kubectl create service clusterip web --tcp=80:8080 --dry-run=client -o yaml
kubectl create configmap cm --from-literal=K=V --dry-run=client -o yaml
kubectl create secret generic s --from-literal=K=V --dry-run=client -o yaml
kubectl create role r --verb=get --resource=pods --dry-run=client -o yaml
kubectl expose deployment web --port=80 --dry-run=client -o yaml
```

---

## Debugging

```bash
kubectl logs backend-abc
kubectl logs backend-abc -f --tail=50
kubectl logs backend-abc --previous            # the CRASHED container
kubectl logs backend-abc -c wait-for-postgres  # a specific container
kubectl logs -l app=backend --prefix --tail=20 # every pod of a workload
kubectl logs backend-abc --since=10m

kubectl exec -it backend-abc -- sh
kubectl exec backend-abc -- env
kubectl exec backend-abc -c backend -- ls /app

kubectl debug -it backend-abc --image=busybox --target=backend
kubectl debug node/devops-worker -it --image=busybox

kubectl port-forward pod/backend-abc 8080:8080
kubectl port-forward svc/backend 8080:8080
kubectl port-forward deploy/backend 8080:8080

kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl get events -A --field-selector type=Warning
kubectl get events --field-selector reason=Unhealthy

kubectl top nodes
kubectl top pods --containers
kubectl top pods -A --sort-by=memory | head
```

### Throwaway test pods

```bash
kubectl run t --rm -it --image=busybox:1.36 -- sh
kubectl run t --rm -i --image=busybox:1.36 --restart=Never -- wget -qO- backend:8080/health
kubectl run t --rm -i --image=busybox:1.36 --restart=Never -- nslookup postgres
kubectl run t --rm -it --image=nicolaka/netshoot -- bash     # dig, curl, tcpdump, ss
kubectl run pg --rm -it --image=postgres:16-alpine -- psql -h postgres -U devboard -d devboard
```

---

## Deployments and rollouts

```bash
kubectl rollout status  deployment/backend
kubectl rollout history deployment/backend
kubectl rollout history deployment/backend --revision=3
kubectl rollout undo    deployment/backend
kubectl rollout undo    deployment/backend --to-revision=2
kubectl rollout pause   deployment/backend
kubectl rollout resume  deployment/backend
kubectl rollout restart deployment/backend      # same image, new pods

kubectl get deploy,rs,pods
kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].name}'
```

`kubectl rollout restart` is how you pick up a changed ConfigMap or Secret. It
stamps a timestamp annotation on the pod template, which triggers a normal
rolling update.

---

## Services and networking

```bash
kubectl get svc -A
kubectl describe svc backend

kubectl get endpoints backend                   # THE debugging command
kubectl get endpointslices -l kubernetes.io/service-name=backend

kubectl get svc backend -o jsonpath='{.spec.selector}'
kubectl get pods --show-labels                  # compare with the selector above
kubectl get svc backend -o jsonpath='{.spec.ports[0].nodePort}'

kubectl get ingress -A
kubectl get ingressclass
kubectl describe ingress devboard               # Events say if it was claimed

kubectl get gatewayclass,gateway,httproute -A
```

**When a Service does not work, `kubectl get endpoints` is always the first
command.** `<none>` means selector or readiness; populated means ports,
networking or the app.

---

## Config and secrets

```bash
kubectl get configmaps
kubectl describe configmap devboard-config
kubectl get configmap devboard-config -o jsonpath='{.data.POSTGRES_HOST}'
kubectl create configmap cm --from-file=dir/
kubectl create configmap cm --from-env-file=.env
kubectl patch configmap devboard-config -p '{"data":{"LOG_LEVEL":"debug"}}'

kubectl get secrets
kubectl describe secret devboard-secrets        # byte counts only
kubectl get secret devboard-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
kubectl get secret devboard-secrets -o go-template=\
'{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'

kubectl create secret tls devboard-tls --cert=tls.crt --key=tls.key
kubectl create secret docker-registry regcred \
  --docker-server=ghcr.io --docker-username=u --docker-password=p

echo -n 'value' | base64                        # -n MATTERS
echo 'dmFsdWU=' | base64 -d

# after changing either, pods must be recreated to see env vars
kubectl rollout restart deployment/backend
```

---

## Storage

```bash
kubectl get storageclass
kubectl get pv                                  # cluster-scoped: no -n
kubectl get pvc -n devboard
kubectl describe pvc postgres-data -n devboard  # WHY is it Pending

kubectl get pod <pod> -o jsonpath='{.spec.volumes}'
kubectl exec deploy/postgres -- df -h /var/lib/postgresql/data

kubectl patch pvc postgres-data -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
kubectl patch pv <pv> -p '{"spec":{"claimRef":null}}'      # release a Retained PV
```

---

## StatefulSets

```bash
kubectl get statefulset,pods,pvc
kubectl scale statefulset postgres --replicas=3
kubectl rollout status statefulset/postgres

kubectl patch statefulset postgres -p \
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'   # canary

kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard -c '\dt'
kubectl run dns --rm -i --image=busybox:1.36 --restart=Never -- \
  nslookup postgres-0.postgres-headless

kubectl delete statefulset postgres --cascade=orphan       # keep the pods
```

Naming: pod `postgres-0`, PVC `data-postgres-0`, DNS
`postgres-0.postgres-headless.devboard.svc.cluster.local`.

---

## Autoscaling

```bash
kubectl get hpa
kubectl describe hpa backend                    # Conditions + Events = the truth
kubectl get hpa backend -w
kubectl get hpa backend \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}'

kubectl autoscale deployment backend --cpu-percent=50 --min=2 --max=10
kubectl delete hpa backend
```

`<unknown>` almost always means a missing CPU **request**, or metrics-server not
working.

---

## Nodes and scheduling

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
kubectl describe node devops-worker | grep -A8 "Allocated resources"
kubectl describe node devops-worker | grep -A3 Taints

kubectl label node devops-worker disktype=ssd
kubectl label node devops-worker disktype-

kubectl taint nodes devops-worker key=value:NoSchedule
kubectl taint nodes devops-worker key=value:NoSchedule-       # trailing dash

kubectl cordon   devops-worker
kubectl drain    devops-worker --ignore-daemonsets --delete-emptydir-data
kubectl uncordon devops-worker

kubectl get daemonsets -A
kubectl get pdb -A

# where did everything land?
kubectl get pods -n devboard -o wide | awk 'NR>1{print $7}' | sort | uniq -c
```

---

## RBAC

```bash
kubectl auth can-i create deployments -n devboard
kubectl auth can-i --list -n devboard
kubectl auth can-i delete pods -n devboard \
  --as=system:serviceaccount:devboard:devboard-intern
kubectl auth can-i list pods --as=jane --as-group=developers

kubectl get roles,rolebindings -n devboard
kubectl get clusterroles | grep -vE "^system:"
kubectl describe clusterrole view
kubectl get clusterrolebindings -o wide | grep cluster-admin

kubectl create serviceaccount ci -n devboard
kubectl create role viewer --verb=get,list,watch --resource=pods -n devboard
kubectl create rolebinding ci-view --role=viewer --serviceaccount=devboard:ci -n devboard
kubectl create rolebinding team --clusterrole=admin --group=devs -n devboard
```

Impersonation string: `system:serviceaccount:<namespace>:<name>`.

---

## Deleting

```bash
kubectl delete -f manifest.yaml                 # exactly what that file created
kubectl delete pod nginx
kubectl delete pods -l app=backend
kubectl delete namespace devboard               # EVERYTHING inside it
kubectl delete deployment x --cascade=orphan    # keep the pods

kubectl delete pod nginx --force --grace-period=0     # LAST RESORT
```

---

## kind

```bash
kind create cluster --config cluster/kind-config.yaml
kind get clusters
kind delete cluster --name devops
kind load docker-image devboard-backend:1.0 --name devops

docker ps                                        # nodes are containers
docker exec -it devops-control-plane bash
docker exec devops-worker crictl images | grep devboard
docker port devops-control-plane                 # which ports are published
```

---

## The five commands that solve most problems

```bash
kubectl get pods -n devboard -o wide
kubectl describe pod <pod> -n devboard          # READ THE EVENTS
kubectl logs <pod> -n devboard --previous
kubectl get endpoints <svc> -n devboard
kubectl get events -n devboard --sort-by=.lastTimestamp | tail -20
```
