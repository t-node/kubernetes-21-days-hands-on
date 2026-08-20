# CKA 31 — Troubleshooting: Three Failure Domains

**Time:** 120-150 minutes
**Prerequisites:** [Day 21](../../days/day-21-break-and-fix-troubleshooting/), [CKA 02](../02-container-runtimes-and-crictl/), [CKA 05](../05-manual-scheduling-and-static-pods/), [CKA 23](../23-service-networking/)
**Source lectures:** 283, 284, 286, 287, 289, 290, 292, 293

[Day 21](../../days/day-21-break-and-fix-troubleshooting/) broke applications.
This assignment breaks **the cluster**, and its subject is not any individual
fault — it is the **method** for finding one when you do not know where to look.

**The eight scenarios in Part 2 are deliberately unlabelled.** You are told
something is wrong, not what.

---

## Part 1 - Concepts

### 31.1 Draw the map before you touch anything

```
   user
     |
   [ Ingress ]  ---------------------- controller running? rules match?
     |
   [ Service ] ----------------------- endpoints? selector matches?
     |
   [ Pod ] --------------------------- Running? Ready? restarts?
     |
   [ Container ] --------------------- logs? previous logs? exit code?
     |
   [ Node ] -------------------------- Ready? kubelet alive? pressure?
     |
   [ Control plane ] ----------------- scheduler? controller-manager? etcd?
```

**Every fault lives at exactly one of those layers**, and the whole method is
finding which. Writing the map down before you start is not ceremony — it is what
stops you checking the same three things repeatedly while the fault sits two
layers away.

**Start from the end you know most about.** A user report ("the site is down")
starts at the top; an alert ("node NotReady") starts at the bottom.

### 31.2 The three domains

| Domain | Symptom shape | First command |
|---|---|---|
| **Application** | one workload is broken, everything else is fine | `kubectl get pods` |
| **Control plane** | **nothing changes** -- new pods never appear, scaling does nothing | `kubectl -n kube-system get pods` |
| **Worker node** | one node's workloads are affected; others are fine | `kubectl get nodes` |

**Those three questions, in that order, place almost every fault.** Run all three
before forming a theory:

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get pods -A | grep -v Running
```

A fourth cuts across all of them — **networking** (31.6): every object is healthy
and the packets do not arrive.

### 31.3 Domain 1 — application failure

Walk the map downward, checking every link:

```bash
# 1. is it reachable at all?
kubectl run t --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -m5 http://svc

# 2. does the Service have endpoints?      <- THE most common fault
kubectl get endpoints web
kubectl describe svc web | grep -A2 Endpoints

# 3. if not: does the selector match the pods?
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods --show-labels

# 4. are the pods Running AND Ready?
kubectl get pods -o wide

# 5. what does the pod say about itself?
kubectl describe pod web-xxx | tail -20

# 6. what does the application say?
kubectl logs web-xxx
kubectl logs web-xxx --previous          # the instance that CRASHED
```

**Step 2 resolves more incidents than the rest combined.** An empty `Endpoints`
means one of exactly three things: the selector matches nothing, the pods are not
`Ready`, or there are no pods.

**Step 6's `--previous` is the one people forget.** A crash-looping pod's current
logs come from the container that just started and has not failed yet; the reason
is in the *previous* container's output.

Then repeat the walk for the next tier — the web pod's failure may be that the
database Service has no endpoints.

### 31.4 Domain 2 — control plane failure

**The signature is that nothing changes.** Existing pods keep running and serving
traffic; anything requiring a decision silently does not happen.

| What is broken | Symptom |
|---|---|
| **kube-apiserver** | `kubectl` itself fails -- connection refused, or a timeout |
| **kube-scheduler** | new pods stay `Pending` **with no events** |
| **kube-controller-manager** | Deployments do not create ReplicaSets; scaling does nothing; endpoints never update |
| **etcd** | the API server reports `etcdserver:` errors while running fine |

**"Pending with no events" versus "Pending with `FailedScheduling`" is the key
distinction** ([CKA 05](../05-manual-scheduling-and-static-pods/),
[CKA 06](../06-priority-schedulers-profiles/)): an event means a scheduler looked
and refused; **silence means nothing is watching.**

Control-plane components are **static pods**
([CKA 05](../05-manual-scheduling-and-static-pods/)):

```bash
kubectl -n kube-system get pods -o wide
kubectl -n kube-system logs kube-scheduler-<node>
kubectl -n kube-system describe pod kube-controller-manager-<node> | tail -20
```

**When `kubectl` itself is gone, drop to the node**
([CKA 02](../02-container-runtimes-and-crictl/)):

```bash
crictl ps -a | grep -E "apiserver|scheduler|controller|etcd"
crictl logs <container-id>
crictl logs --previous <container-id>        # read the one that EXITED
journalctl -u kubelet --no-pager | tail -40
ls -l /etc/kubernetes/manifests/
```

**A static pod that will not start is almost always its manifest**: a bad flag, a
path that does not exist, or a volume that was never mounted. The kubelet journal
says which.

### 31.5 Domain 3 — worker node failure

```bash
kubectl get nodes
kubectl describe node <name> | grep -A10 Conditions
```

| Condition | `True` means |
|---|---|
| `MemoryPressure` | low on memory -- the kubelet will start evicting |
| `DiskPressure` | low disk -- images and dead containers are garbage-collected first |
| `PIDPressure` | too many processes |
| `Ready` | **the node is healthy** (note the inverted sense) |

**`Unknown` on every condition means the node stopped talking to the API
server.** Not unhealthy — *unreachable*. `LastHeartbeatTime` says when it stopped.

That distinction decides where you go next:

- **`Ready: False` with a reason** — the kubelet is running and telling you what
  is wrong. Read the reason (`KubeletNotReady`, `NetworkPluginNotReady`).
- **`Unknown`** — the kubelet is not reporting at all. **Get onto the machine.**

```bash
systemctl status kubelet
journalctl -u kubelet -n 50 --no-pager
df -h /var/lib/kubelet /var/lib/containerd
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
```

**The certificate check is the one that surprises people**
([CKA 13](../13-tls-in-kubernetes/)): a kubelet whose client certificate expired
runs perfectly and cannot authenticate, so the node goes `Unknown` with no local
symptom at all.

**A cordoned or tainted node is not a failure**, and it looks like one:

```bash
kubectl get nodes                          # SchedulingDisabled
kubectl describe node <n> | grep -i taint
```

### 31.6 The fourth domain — networking

Every object is healthy and packets do not arrive. Work the layers in order,
because each depends on the one below:

```bash
# 1. pod to pod, by IP -- is the CNI working at all? (CKA 22)
kubectl exec pod-a -- ping -c2 <pod-b-ip>

# 2. pod to Service, by ClusterIP -- is kube-proxy working? (CKA 23)
kubectl exec pod-a -- curl -m5 http://<clusterIP>

# 3. pod to Service, by NAME -- is DNS working? (CKA 24)
kubectl exec pod-a -- nslookup web
kubectl exec pod-a -- cat /etc/resolv.conf

# 4. is something dropping it? (CKA 18)
kubectl get netpol -A
```

**Each step isolates one layer.** Working by IP and failing by name is DNS;
working pod-to-pod and failing to a ClusterIP is kube-proxy; failing at step 1 is
the CNI or a policy.

**The two error strings that split the search in half:**

| | Means |
|---|---|
| `connection refused`, instantly | something answered and said no -- a REJECT rule, or no endpoints |
| **timeout** | **the packet went somewhere and nothing came back** -- routing, policy, or a dead backend |

### 31.7 Statuses, and which domain they point at

| Status | Domain | Usual cause |
|---|---|---|
| `Pending` + `FailedScheduling` | application | resources, taints, affinity, a PVC that will not bind |
| **`Pending` + no events** | **control plane** | **no scheduler is running** |
| `ContainerCreating`, stuck | node / network | CNI, a missing Secret or ConfigMap, a volume that will not mount |
| `ImagePullBackOff` | application | the tag, the registry, or the pull secret |
| `CrashLoopBackOff` | application | read `logs --previous` |
| `Error` / unexpected `Completed` | application | the command exited |
| `Terminating`, stuck | control plane / application | a finalizer ([CKA 19](../19-crds-controllers-operators/)) |
| `Running` but `0/1` | application | the readiness probe |
| `Evicted` | **node** | memory or disk pressure |
| `Unknown` / `NodeLost` | **node** | the kubelet stopped reporting |

**`ImagePullBackOff` proves the CNI worked** — the sandbox was created, so
networking is off the list ([CKA 22](../22-pod-networking-and-cni/) C4). Statuses
carry more information than they appear to.

### 31.8 The method, in four questions

Whatever the report, answer these before forming a theory:

1. **What changed?** A deploy, an upgrade, a node reboot, a certificate that
   expired at midnight. Most incidents have an answer, and it is usually the
   fastest route.
2. **What is the blast radius?** One pod, one workload, one node, or everything?
   That maps directly onto the three domains (31.2).
3. **Which layer?** Walk the map (31.1) from whichever end you know, and
   **bisect** — do not walk one step at a time when you can test the middle.
4. **What does the object say about itself?** `describe` for events, `logs` for
   the application, `logs --previous` for the crash, `crictl` when `kubectl` is
   gone.

**Bisecting is the habit that separates fast diagnosis from slow.** With seven
layers, testing the middle one halves the search space; walking from the top
averages three and a half checks and feels like progress the whole time.

---

## Part 2 - Hands-on lab

### Setup

```bash
kubectl config use-context kind-devops
kubectl apply -f solution/app.yaml
kubectl -n cka31 rollout status deployment/web --timeout=120s
kubectl -n cka31 rollout status deployment/db  --timeout=120s
```

Confirm the healthy baseline — **you need to know what "working" looks like
before you break it:**

```bash
kubectl -n cka31 get pods,svc,endpoints
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "web -> %{http_code}\n" http://web
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "db  -> %{http_code}\n" http://db:5432
```

Both should return `200`.

### The exercise

```bash
bash solution/break.sh list
```

**Eight scenarios. What each one does is not printed** — not by `break.sh`, not
by this README. The answers are in
[solution/README.md](solution/README.md), and reading them before you have
finished is the one way to waste this assignment.

For each scenario:

```bash
bash solution/break.sh 1
# ...wait 30-60 seconds...
```

**Then work the method from 31.8, and write down your answers before you touch
`restore.sh`:**

| Question | Your answer |
|---|---|
| What is the blast radius? | one pod / one workload / one node / everything |
| Which domain? | application / control plane / node / network |
| Which layer of the map? | |
| What is the fault, exactly? | |
| What is the command that fixes it? | |

Then:

```bash
bash solution/restore.sh
```

and compare against
[solution/README.md](solution/README.md).

### Do the first one together

```bash
bash solution/break.sh 1
sleep 20
```

**The three orientation commands, always first (31.2):**

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get pods -n cka31
```

All healthy. **So it is not the control plane and not a node** — two of four
domains eliminated in three commands, before looking at anything specific.

**Now the symptom:**

```bash
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "web -> %{http_code}\n" http://web
```

```
web -> 000
```

`000` is curl reporting no answer at all. Was it refused or did it time out?

```bash
kubectl -n cka31 exec client -- curl -s -m5 http://web 2>&1 | tail -2
```

**Refused instantly, not a timeout** — which from 31.6 means something answered
and said no. On a ClusterIP, that is the `REJECT` rule kube-proxy writes for a
Service with no endpoints ([CKA 23](../23-service-networking/)).

**Test the hypothesis directly rather than guessing further:**

```bash
kubectl -n cka31 get endpoints web
```

```
NAME   ENDPOINTS   AGE
web    <none>      5m
```

**Confirmed in one command.** Now the three causes of an empty `Endpoints`
(31.3): a selector that matches nothing, pods that are not `Ready`, or no pods.

```bash
kubectl -n cka31 get pods -l app=web          # 3 pods, all 1/1 Ready
kubectl -n cka31 get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n cka31 get pods --show-labels | head -3
```

```
{"app":"web-frontend"}
web-xxx   1/1  Running  ...  app=web,tier=frontend
```

**The selector says `web-frontend`; the pods say `web`.** Fix:

```bash
kubectl -n cka31 patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
kubectl -n cka31 get endpoints web
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "web -> %{http_code}\n" http://web
```

**Six commands, no guessing, and every one of them eliminated something.** That
is the method — not the answer.

```bash
bash solution/restore.sh
```

### The remaining seven

```bash
bash solution/break.sh 2      # ...through 8
```

Some are harder than scenario 1, and **two of them break things that have
nothing to do with the application** — the symptom appears in `cka31` and the
fault is elsewhere. That is the point.

**When you are ready to be tested properly:**

```bash
bash solution/break.sh random
```

It applies one at random and **does not tell you which**. That is the closest
this repo gets to an exam question.

### Two hints that are not spoilers

**If `kubectl` itself stops working**, none of the scenarios did that on purpose —
but the technique matters, so:

```bash
docker exec devops-control-plane crictl ps -a | grep -E "apiserver|scheduler|controller"
docker exec devops-control-plane sh -c 'crictl logs --previous $(crictl ps -a --name kube-scheduler -q | head -1) 2>&1 | tail -20'
docker exec devops-control-plane journalctl -u kubelet --no-pager | tail -30
```

**If a pod is `Pending`**, the single most informative thing is whether it has
events:

```bash
kubectl -n cka31 describe pod <name> | grep -A5 Events
```

Events mean a scheduler looked and refused. **No events at all means nothing is
watching** (31.4, 31.7).

### Cleanup

```bash
bash solution/restore.sh all
kubectl delete -f solution/app.yaml --ignore-not-found
kubectl get nodes
kubectl -n kube-system get pods
```

**`restore.sh all` is idempotent** — run it any time the cluster is in a state you
are unsure about.

---

## Part 3 - Challenges

### C1 - Triage from a one-line report

For each report, give the **first three commands** you would run and what each
would eliminate:

1. "The website is down."
2. "Deploys aren't going out."
3. "Half our requests are failing."
4. "The cluster is slow."
5. "I can't `kubectl`."

### C2 - Two pods, one symptom

A Deployment has 6 replicas across 3 nodes. Two pods return errors; four are
fine. The application, image and configuration are identical.

Give five possible causes and, for each, the command that confirms or eliminates
it. Which single command narrows it fastest?

### C3 - Nothing is happening

A colleague reports: "I scaled the Deployment to 10 an hour ago and there are
still 3 pods. `kubectl` works fine and `kubectl get deploy` shows `10` desired."

1. Which domain, and how do you know from that sentence alone?
2. Which component, and why not the others?
3. Give the diagnosis commands in order.
4. What else in the cluster is silently broken right now?

### C4 - `Unknown` versus `NotReady`

Explain the difference between a node showing `Ready: False` and one showing
`Ready: Unknown`, what each tells you about where the fault is, and why the
second is worse to diagnose. Give the commands for each, and say which one you
cannot answer from `kubectl` alone.

### C5 - Write the runbook

Write a one-page triage runbook for an on-call engineer with six months of
Kubernetes experience. It must fit on one screen, start from a pager alert, and
route to the right domain within five commands. Say explicitly what you left out
and why.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks that the cluster is in a healthy baseline: all nodes `Ready` and
schedulable, every `kube-system` pod running, the scheduler and controller
manager holding their leases, CoreDNS with endpoints, and the `cka31`
application reachable end to end. **Run it after `restore.sh` to confirm you
really did put everything back.**

---

## Part 5 - Exam notes

**The orientation trio, every time**

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get pods -A | grep -v Running
```

**Application**

```bash
kubectl get endpoints SVC                       # the highest-value single command
kubectl get svc SVC -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods --show-labels
kubectl describe pod POD | tail -20
kubectl logs POD --previous                     # the container that CRASHED
kubectl logs POD -c CONTAINER --previous        # multi-container
kubectl get events -n NS --sort-by=.lastTimestamp | tail -20
```

**Control plane**

```bash
kubectl -n kube-system get pods -o wide
kubectl -n kube-system logs kube-scheduler-NODE
kubectl -n kube-system get lease                # who is the active leader?
# ...and when kubectl is gone:
crictl ps -a | grep -E "apiserver|scheduler|controller|etcd"
crictl logs --previous <id>
journalctl -u kubelet --no-pager | tail -40
ls -l /etc/kubernetes/manifests/
```

**Node**

```bash
kubectl describe node NODE | grep -A10 Conditions
kubectl describe node NODE | grep -i taint
kubectl top nodes
systemctl status kubelet && journalctl -u kubelet -n 50 --no-pager
df -h /var/lib/kubelet /var/lib/containerd
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
```

**Network**

```bash
kubectl exec POD -- ping -c2 <pod-ip>           # CNI
kubectl exec POD -- curl -m5 http://<clusterIP> # kube-proxy
kubectl exec POD -- nslookup SVC                # DNS
kubectl exec POD -- cat /etc/resolv.conf
kubectl get netpol -A
```

**Traps**

- **`kubectl logs` without `--previous` shows the wrong container** for anything
  crash-looping.
- **`Pending` with no events means no scheduler**, not a resource problem.
- **An empty `Endpoints` has exactly three causes**: selector, readiness, or no
  pods.
- **Instant `connection refused` and a timeout are different faults.** The first
  means something answered.
- **`ImagePullBackOff` proves networking worked.**
- **`Unknown` conditions mean the kubelet is not reporting** — get onto the
  machine.
- **A cordoned or tainted node looks broken and is not.**
- **`kubectl` failing is not always the API server** — check your kubeconfig and
  your own certificate's expiry too ([CKA 13](../13-tls-in-kubernetes/)).
- **When `kubectl` is gone, `crictl` is the only window** — and read the
  **exited** container's logs, not the restarting one.
- **Check `kubectl get events -A --sort-by=.lastTimestamp` early.** Events expire
  after about an hour, so the evidence is perishable.

---

**Previous:** [CKA 30 — Kustomize: Patches, Overlays and Components](../30-kustomize-patches-overlays-components/)
**Next:** [CKA 32 — JSONPath and Output Formatting](../32-jsonpath/)
