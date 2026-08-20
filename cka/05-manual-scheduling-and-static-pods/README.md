# CKA 05 — Manual Scheduling and Static Pods

**Time:** 60-75 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [Day 18](../../days/day-18-scheduling-taints-affinity-daemonsets/)
**Source lectures:** 50, 51, 53, 72, 74

CKA 01 established that the scheduler's entire job is writing `spec.nodeName`.
This assignment takes that literally: you will do the scheduler's job by hand,
in the two ways that work, and then meet the pod type that **bypasses the
control plane completely** — the one your whole cluster is built out of.

---

## Part 1 - Concepts

### 5.1 Scheduling is one field

Every Pod has `spec.nodeName`. You normally never write it, and Kubernetes fills
it in. That is the entire scheduling handshake:

```
1. you create a Pod            nodeName: <empty>   status: Pending
2. the scheduler notices       (it watches for pods with no nodeName)
3. it filters and scores       -> picks devops-worker
4. it writes nodeName          via a BINDING object
5. the kubelet on that node    sees a pod bearing its own name, and starts it
```

**No scheduler means step 4 never happens, so pods sit `Pending` forever** —
which you proved in CKA 01 Step 3.

Two ways to do step 4 yourself:

**Method 1 — set `nodeName` at creation.**

```yaml
spec:
  nodeName: devops-worker
  containers:
    - name: nginx
      image: nginx:alpine
```

Simple and immediate. **Only works at creation time.**

**Method 2 — POST a Binding to an existing pod.**

`nodeName` is immutable, so you cannot edit an already-created pod (CKA 08). To
assign an existing `Pending` pod you must do exactly what the scheduler does —
create a **Binding** object against the pod's `/binding` subresource:

```yaml
apiVersion: v1
kind: Binding
metadata:
  name: nginx           # the POD's name
target:
  apiVersion: v1
  kind: Node
  name: devops-worker
```

```bash
curl -X POST --header "Content-Type: application/json" \
  --data "$(cat binding.json)" \
  http://localhost:8001/api/v1/namespaces/default/pods/nginx/binding
```

Note it must be **JSON**, not YAML, and it goes to the pod's binding endpoint.
Use `kubectl proxy` (CKA 14) so you do not have to pass certificates.

> **`nodeName` bypasses everything.** No filtering, no scoring, no taint check,
> no resource check. If the node cannot fit the pod, the **kubelet rejects it**
> and the pod sits `OutOfcpu` or `OutOfmemory` forever — with nothing to
> reschedule it, because no controller owns that decision. Debugging tool only.

### 5.2 Static pods: the kubelet acting alone

Now the deeper idea.

Strip away the API server, scheduler, controllers and etcd. A lone machine with
just a **kubelet** and a container runtime. Can it run anything?

Yes. The kubelet can read pod manifests **from a directory on disk** and run
them, with no cluster involvement whatsoever. Those are **static pods**.

```
        /etc/kubernetes/manifests/
                  |
                  |  kubelet watches this directory
                  v
            creates the pod
            restarts it if it dies
            recreates it if the file changes
            deletes it if the file is removed
```

Four behaviours worth stating precisely:

| You do | The kubelet does |
|---|---|
| put a manifest in the directory | creates the pod |
| the container crashes | restarts it |
| edit the file | **recreates the pod** |
| delete the file | **deletes the pod** |

**That third row is why every control-plane repair in this course works by
editing a file and waiting.** There is no `systemctl restart kube-apiserver`,
because there is no service — there is a file, and a kubelet watching it.

### 5.3 What static pods cannot be

> **Only Pods.** Not Deployments, not ReplicaSets, not Services, not Jobs.

The kubelet understands pods and nothing else. Every other kind exists because a
**controller** in the control plane reconciles it — and in a static-pod world
there is no control plane. Put a Deployment manifest in that directory and
nothing happens.

### 5.4 Mirror pods

If the node *is* part of a cluster, the kubelet also creates a **mirror pod** in
the API server so the static pod is visible:

```bash
kubectl get pods -n kube-system | grep control-plane
```

The mirror is **read-only**:

- `kubectl delete pod etcd-devops-control-plane` appears to work — and the pod
  comes straight back, because you deleted the mirror, not the pod.
- The name always has **`-<nodename>` appended**: `kube-apiserver-devops-control-plane`.
- Its `ownerReference` is the **Node**, not a ReplicaSet — the test you used in
  CKA 01 and Day 01.

**To actually delete a static pod, remove its file.** Nothing else works.

### 5.5 Finding the directory

Two configuration routes, and you must know both:

```bash
# 1. modern (kubeadm) -- kubelet config file
grep staticPodPath /var/lib/kubelet/config.yaml

# 2. legacy -- a flag on the kubelet service
ps aux | grep [k]ubelet | grep -o '\--pod-manifest-path=[^ ]*'
```

The procedure when you land on an unknown cluster: check the kubelet's
`--config` flag, open that file, read `staticPodPath`. If there is no `--config`,
look for `--pod-manifest-path` directly.

### 5.6 Why this exists

Because it solves the bootstrap problem. **How do you run the API server as a
pod, when running a pod normally requires an API server?**

You do not. You put `kube-apiserver.yaml` in the static pod directory and let
the kubelet start it with no cluster at all. Once it is up, the rest of the
control plane can be pods too.

**That is precisely how `kubeadm` builds a cluster** — and why `kubeadm upgrade`
can swap control-plane images but cannot touch the kubelet (CKA 01, CKA 12).

### 5.7 Static pods vs DaemonSets

A frequent interview question:

| | **Static pod** | **DaemonSet** |
|---|---|---|
| Created by | the **kubelet**, from a file | the DaemonSet controller, via the API |
| Needs a control plane | **no** | yes |
| Survives an API server outage | **yes** | existing pods do |
| Scheduled by kube-scheduler | **no** | **no** — the controller sets nodeName |
| Used for | **control-plane components** | node agents: CNI, kube-proxy, log shippers |
| Delete it by | removing the file | deleting the DaemonSet |

**Both are ignored by the scheduler.** They arrive at their node by a different
route than every other pod.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka05 2>/dev/null
kubectl config set-context --current --namespace=cka05
```

### Step 1: A pod with nowhere to go

Remove the scheduler so nothing assigns pods:

```bash
docker exec devops-control-plane mv \
  /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 20
kubectl get pods -n kube-system | grep -c scheduler        # 0
```

```bash
kubectl run stranded --image=nginx:alpine
sleep 8
kubectl get pod stranded
kubectl get pod stranded -o jsonpath='{.spec.nodeName}{"\n"}'    # empty
kubectl describe pod stranded | grep -A3 Events                  # nothing
```

`Pending`, empty `nodeName`, **no events**. Nothing has an opinion.

### Step 2: Method 1 — schedule at creation

```bash
kubectl apply -f solution/01-nodename-pod.yaml
sleep 8
kubectl get pod manual-nodename -o wide
```

**Running, with no scheduler in the cluster.** You wrote `nodeName` yourself, the
kubelet on that node noticed, and started it.

### Step 3: Method 2 — bind an existing pod

`stranded` is still Pending. You cannot edit it:

```bash
kubectl patch pod stranded -p '{"spec":{"nodeName":"devops-worker"}}'
```

```
Forbidden: pod updates may not change fields other than ...
```

So do what the scheduler does — POST a Binding:

```bash
kubectl proxy --port=8001 &
sleep 2

cat > /tmp/binding.json <<'EOF'
{
  "apiVersion": "v1",
  "kind": "Binding",
  "metadata": { "name": "stranded" },
  "target": { "apiVersion": "v1", "kind": "Node", "name": "devops-worker" }
}
EOF

curl -s -X POST --header "Content-Type: application/json" \
  --data @/tmp/binding.json \
  http://localhost:8001/api/v1/namespaces/cka05/pods/stranded/binding

sleep 8
kubectl get pod stranded -o wide
kill %1
```

**`stranded` is now Running on `devops-worker`.** You just performed step 4 of
the handshake in 5.1 by hand — this is literally the API call the scheduler
makes.

Restore the scheduler:

```bash
docker exec devops-control-plane mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 25
kubectl get pods -n kube-system | grep scheduler
kubectl delete pod stranded manual-nodename --ignore-not-found
```

### Step 4: Find the static pod directory two ways

```bash
docker exec devops-control-plane grep staticPodPath /var/lib/kubelet/config.yaml

docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ubelet | xargs -n1 | grep -E 'config|pod-manifest'"
```

kind uses the modern route: a `--config` flag pointing at
`/var/lib/kubelet/config.yaml`, which contains
`staticPodPath: /etc/kubernetes/manifests`.

```bash
docker exec devops-control-plane ls -la /etc/kubernetes/manifests/
```

**Four files. Your entire control plane is four files in a directory.**

### Step 5: Create a static pod

```bash
docker cp solution/02-static-web.yaml devops-control-plane:/etc/kubernetes/manifests/static-web.yaml
sleep 20

kubectl get pods -A | grep static-web
```

```
default   static-web-devops-control-plane   1/1   Running
```

Note the name: **`-devops-control-plane` appended automatically.** That suffix is
how you spot a static pod at a glance.

Confirm what created it:

```bash
kubectl get pod static-web-devops-control-plane \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'      # Node
docker exec devops-control-plane crictl ps --name static-web
```

`Node`, not `ReplicaSet` — the kubelet made it, from a file.

### Step 6: Prove the mirror is read-only

```bash
kubectl delete pod static-web-devops-control-plane
sleep 12
kubectl get pods -A | grep static-web
```

**It is back.** You deleted the *mirror*; the kubelet still sees the file and
recreated the pod. Delete it properly:

```bash
docker exec devops-control-plane rm /etc/kubernetes/manifests/static-web.yaml
sleep 15
kubectl get pods -A | grep -c static-web        # 0
```

**Removing the file is the only thing that works.**

### Step 7: Edit a file, watch the pod be recreated

```bash
docker cp solution/02-static-web.yaml devops-control-plane:/etc/kubernetes/manifests/static-web.yaml
sleep 15
kubectl get pod static-web-devops-control-plane -o jsonpath='{.spec.containers[0].image}{"\n"}'

docker exec devops-control-plane sh -c \
  "sed -i 's|nginx:1.27-alpine|nginx:1.26-alpine|' /etc/kubernetes/manifests/static-web.yaml"
sleep 20
kubectl get pod static-web-devops-control-plane -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

The image changed with **no `kubectl apply` and no restart command**. This is the
mechanism behind every control-plane repair in CKA 12 and CKA 15.

```bash
docker exec devops-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

### Step 8: Prove a Deployment will not work

```bash
docker cp solution/03-static-deployment-BAD.yaml \
  devops-control-plane:/etc/kubernetes/manifests/bad-deploy.yaml
sleep 20

kubectl get deploy -A | grep -c static-deploy       # 0
kubectl get pods -A | grep -c static-deploy         # 0
docker exec devops-control-plane journalctl -u kubelet -n 20 --no-pager 2>/dev/null | grep -i -m3 "deployment\|manifest" || echo "(kubelet silently ignored it)"
```

**Nothing happened.** The kubelet understands Pods and nothing else — section
5.3, demonstrated.

```bash
docker exec devops-control-plane rm /etc/kubernetes/manifests/bad-deploy.yaml
```

---

## Validate

```bash
# static pod directory, found the right way
docker exec devops-control-plane grep staticPodPath /var/lib/kubelet/config.yaml

# control-plane pods are owned by the Node
for c in kube-apiserver etcd kube-scheduler kube-controller-manager; do
  printf "%-26s %s\n" "$c" \
   "$(kubectl get pod ${c}-devops-control-plane -n kube-system \
      -o jsonpath='{.metadata.ownerReferences[0].kind}')"
done

# nodeName scheduling works with no scheduler involved
kubectl apply -f solution/01-nodename-pod.yaml
kubectl wait --for=condition=Ready pod/manual-nodename -n cka05 --timeout=60s
kubectl get pod manual-nodename -n cka05 -o wide
kubectl delete -f solution/01-nodename-pod.yaml
```

You are done when you can answer, without looking:

1. What single field does the scheduler write, and via what object?
2. Why can you not `kubectl edit` a Pending pod onto a node?
3. Name the four things the kubelet does in response to that directory.
4. Why can a static pod not be a Deployment?
5. How do you delete a static pod?
6. Name two differences between a static pod and a DaemonSet pod.

---

## Break it

**A. `nodeName` a node that does not exist.**

```bash
kubectl run ghost --image=nginx:alpine --overrides='{"spec":{"nodeName":"no-such-node"}}'
sleep 10
kubectl get pod ghost
kubectl describe pod ghost | grep -A3 Events
kubectl delete pod ghost --force --grace-period=0
```

`Pending` forever with **no events** — indistinguishable at a glance from "the
scheduler is down". The tell is that `nodeName` is *set*: nothing is wrong with
scheduling, the named kubelet simply does not exist to claim it.

**B. `nodeName` a node with no room.**

```bash
kubectl run greedy -n cka05 --image=nginx:alpine \
  --overrides='{"spec":{"nodeName":"devops-worker","containers":[{"name":"greedy","image":"nginx:alpine","resources":{"requests":{"cpu":"64"}}}]}}'
sleep 10
kubectl get pod greedy -n cka05
kubectl describe pod greedy -n cka05 | grep -A4 -i "outof\|Events"
kubectl delete pod greedy -n cka05 --force --grace-period=0 2>/dev/null
```

`OutOfcpu`. **The scheduler would have refused to place this; `nodeName` skipped
that check**, so the kubelet accepted it and then rejected it locally. Nothing
reschedules it — this is exactly why `nodeName` is a debugging tool only.

**C. Break a control-plane static pod with bad YAML.**

The most instructive failure in the whole track. Do it on kind, where recovery
is 90 seconds.

```bash
docker exec devops-control-plane sh -c \
  "cp /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/sched.bak && \
   echo '  THIS IS NOT VALID YAML' >> /etc/kubernetes/manifests/kube-scheduler.yaml"
sleep 25
kubectl get pods -n kube-system | grep -c scheduler
```

The pod is gone and `kubectl` gives you no clue why — the *scheduler* is not what
serves `kubectl`. Diagnose from the node, which is why CKA 02 came first:

```bash
docker exec devops-control-plane journalctl -u kubelet -n 30 --no-pager | grep -i -m5 "scheduler\|yaml\|parse"
```

The kubelet logs the parse error. **A YAML mistake in that directory silently
removes a component.** Repair:

```bash
docker exec devops-control-plane cp /tmp/sched.bak /etc/kubernetes/manifests/kube-scheduler.yaml
sleep 25
kubectl get pods -n kube-system | grep scheduler
```

**D. Try to scale a static pod.**

```bash
docker cp solution/02-static-web.yaml devops-control-plane:/etc/kubernetes/manifests/static-web.yaml
sleep 15
kubectl scale pod static-web-devops-control-plane --replicas=3 2>&1 | head -2
docker exec devops-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

Pods do not scale — only controllers do, and there is no controller here. Want
three? Write three files, or use a DaemonSet.

---

## Exam-style tasks

1. Create a pod `nginx-manual` on `devops-worker2` **without** using the
   scheduler. *(3 min)*
2. Identify the static pod directory on this cluster, without being told where
   it is. *(2 min)*
3. Create a static pod named `web` running `nginx:alpine` on the control-plane
   node. *(4 min)*
4. Delete a static pod named `web`. *(2 min)*
5. A pod is Pending with `nodeName` already set. Give two possible causes.
   *(2 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# find the directory -- try both, in this order
grep staticPodPath /var/lib/kubelet/config.yaml
ps aux | grep [k]ubelet | grep -o '\--pod-manifest-path=[^ ]*'

# manual scheduling
#   at creation:
spec:
  nodeName: node01
#   for an EXISTING pending pod -- POST a Binding (JSON, to /binding):
kubectl proxy --port=8001 &
curl -X POST -H "Content-Type: application/json" --data @binding.json \
  http://localhost:8001/api/v1/namespaces/NS/pods/POD/binding

# static pods
cp mypod.yaml /etc/kubernetes/manifests/        # create
vi /etc/kubernetes/manifests/mypod.yaml         # edit -> pod is RECREATED
rm /etc/kubernetes/manifests/mypod.yaml         # delete -- the ONLY way

# spot one
kubectl get pod X -o jsonpath='{.metadata.ownerReferences[0].kind}'   # Node
#   ...and the name ends in -<nodename>

# when kubectl cannot help (the control plane is the casualty)
docker exec <node> crictl ps -a --name kube-scheduler
docker exec <node> journalctl -u kubelet -n 30 --no-pager
```

| | Static pod | DaemonSet |
|---|---|---|
| Created by | **kubelet, from a file** | the controller, via the API |
| Needs a control plane | **no** | yes |
| Delete by | **removing the file** | deleting the DaemonSet |
| Scheduled by kube-scheduler | no | no |
| Used for | **control-plane components** | node agents |

**`nodeName` bypasses filtering, scoring, taints and resource checks.** If it
does not fit, the kubelet rejects it and nothing reschedules it.

---

**Previous:** [CKA 04 — Imperative vs Declarative, and kubectl apply](../04-imperative-declarative-and-apply/)
**Next:** [CKA 06 — Priority Classes, Multiple Schedulers and Scheduler Profiles](../06-priority-schedulers-profiles/)
