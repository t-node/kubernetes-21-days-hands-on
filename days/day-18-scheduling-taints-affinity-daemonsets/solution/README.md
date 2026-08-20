# Day 18 solution

**A multi-node cluster is required.** With `kind-config-single-node.yaml` most
of today has nothing to demonstrate.

## The control-plane question, verified

```bash
kubectl describe node devops-control-plane | grep -A3 Taints
kubectl get pod kube-apiserver-devops-control-plane -n kube-system \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'      # Node, not ReplicaSet
kubectl get daemonset kube-proxy -n kube-system \
  -o jsonpath='{.spec.template.spec.tolerations}'
```

## Files

| File | Demonstrates |
|---|---|
| `01-nodeselector.yaml` | exact label match, all or nothing |
| `02-node-affinity.yaml` | required vs preferred, operators, OR/AND |
| `03-pod-anti-affinity.yaml` | HA spreading — **and its replica cap** |
| `04-topology-spread.yaml` | the better way to spread |
| `05-postgres-tolerated.yaml` | taint + toleration + affinity, all three |
| `06-pdb.yaml` | PodDisruptionBudget for safe drains |
| `07-daemonset.yaml` | one pod per node, with the downward API |
| `08-tolerating-only.yaml` | **toleration is permission, not attraction** |
| `09-nodename.yaml` | bypassing the scheduler (never do this) |

## The two experiments that teach the most

**1. Toleration without affinity** (`08-tolerating-only.yaml`)

```bash
kubectl taint nodes devops-worker2 dedicated=database:NoSchedule
kubectl apply -f 08-tolerating-only.yaml
kubectl get pods -n devboard -l demo=toleration -o wide | awk 'NR>1{print $7}' | sort | uniq -c
```

All five tolerate the taint, and they scatter across every node. Nothing pulled
them to the tainted one.

**2. required anti-affinity beyond the node count** (`03-pod-anti-affinity.yaml`)

```bash
kubectl apply -f 03-pod-anti-affinity.yaml
kubectl scale deployment spread-demo --replicas=5 -n devboard
kubectl get pods -n devboard -l demo=antiaffinity
```

3 Running, 2 Pending, permanently. Now picture an HPA driving that at 2 a.m.

## Clean up before Day 19

```bash
kubectl delete -f 01-nodeselector.yaml -f 02-node-affinity.yaml \
  -f 03-pod-anti-affinity.yaml -f 04-topology-spread.yaml \
  -f 07-daemonset.yaml -f 08-tolerating-only.yaml -f 09-nodename.yaml \
  --ignore-not-found

for n in $(kubectl get nodes -o name); do
  kubectl taint ${n#node/} dedicated=database:NoSchedule- 2>/dev/null
  kubectl taint ${n#node/} maintenance=true:NoExecute-    2>/dev/null
  kubectl uncordon ${n#node/}
done
```
