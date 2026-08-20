# CKA 31 solution

> **Do not read this until you have diagnosed the scenario yourself.** The whole
> value of the assignment is in the eight minutes before you look.

---

## The eight scenarios

### Scenario 1 — the Service selector no longer matches

**What was done:** `spec.selector` on the `web` Service changed from `app: web`
to `app: web-frontend`.

| | |
|---|---|
| **Blast radius** | one workload |
| **Domain** | application |
| **Layer** | Service -> Pod |
| **Symptom** | instant `connection refused` from the client; pods all `1/1 Running` |

**Diagnosis:**

```bash
kubectl -n cka31 get endpoints web            # <none>   <- the answer
kubectl -n cka31 get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n cka31 get pods --show-labels
```

**Fix:**

```bash
kubectl -n cka31 patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
```

**The tell is `connection refused` rather than a timeout** (31.6). kube-proxy
writes a `REJECT` rule for a Service with no endpoints
([CKA 23](../../23-service-networking/)), so the failure is instant — which
distinguishes it immediately from a dead backend.

### Scenario 2 — `targetPort` names a port that does not exist

**What was done:** the Service's `targetPort` changed from `http` to `https`.

| | |
|---|---|
| **Blast radius** | one workload |
| **Domain** | application |
| **Layer** | Service -> Pod |
| **Symptom** | **timeout**, not a refusal; the Service *has* endpoints |

**Diagnosis:**

```bash
kubectl -n cka31 get endpoints web
```

```
NAME   ENDPOINTS                    AGE
web    10.244.1.7:0,10.244.2.9:0    12m
```

**Look at the port: `:0`.** The endpoint controller could not resolve the named
port `https` against the pods, so it recorded zero.

```bash
kubectl -n cka31 get svc web -o jsonpath='{.spec.ports}{"\n"}'
kubectl -n cka31 get pod -l app=web -o jsonpath='{.items[0].spec.containers[0].ports}{"\n"}'
```

**Fix:**

```bash
kubectl -n cka31 patch svc web --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
```

**This is the scenario that separates careful reading from pattern-matching.**
`Endpoints` is not empty, so the "no endpoints" reflex does not fire — you have
to read the port number. And the failure is a *timeout* rather than a refusal,
because the rule exists and points at a port nothing is listening on.

### Scenario 3 — an image tag that does not exist

**What was done:** `db`'s image set to `nginx:1.27-alpine-nonexistent`.

| | |
|---|---|
| **Blast radius** | one workload |
| **Domain** | application |
| **Layer** | Pod -> Container |
| **Symptom** | a new `db` pod in `ImagePullBackOff`; the OLD one still `Running` |

**Diagnosis:**

```bash
kubectl -n cka31 get pods
kubectl -n cka31 describe pod db-xxx | grep -A6 Events
kubectl -n cka31 get deploy db -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Fix:**

```bash
kubectl -n cka31 set image deployment/db db=nginx:1.27-alpine
#   ...or, if the previous image is unknown:
kubectl -n cka31 rollout undo deployment/db
```

**Note what did *not* break: the application.** A rolling update keeps the old
ReplicaSet's pods until the new ones are Ready, so `db` is still serving. That is
the Deployment doing its job, and it is why this is a "fix it before the next
restart" problem rather than an outage.

**`ImagePullBackOff` also proves the CNI and the scheduler worked**
([CKA 22](../../22-pod-networking-and-cni/) C4) — the pod was placed and its
sandbox created. Three domains eliminated by one status string.

### Scenario 4 — the scheduler cannot start

**What was done:** `--kubeconfig` in `/etc/kubernetes/manifests/kube-scheduler.yaml`
points at `scheduler-typo.conf`, which does not exist.

| | |
|---|---|
| **Blast radius** | **everything** -- but only new pods |
| **Domain** | **control plane** |
| **Layer** | control plane |
| **Symptom** | existing pods fine; **new pods stay `Pending` with NO events** |

**Diagnosis:**

```bash
kubectl -n cka31 scale deployment web --replicas=5
kubectl -n cka31 get pods                     # two stuck in Pending
kubectl -n cka31 describe pod <pending> | grep -A5 Events    # <none>   <- THE tell
```

**`Pending` with no events at all** means nothing dequeued the pod (31.4,
[CKA 05](../../05-manual-scheduling-and-static-pods/)).

```bash
kubectl -n kube-system get pods | grep scheduler
kubectl -n kube-system logs kube-scheduler-devops-control-plane 2>&1 | tail -5
#   ...or, if the pod is gone entirely:
docker exec devops-control-plane sh -c \
  'crictl logs --previous $(crictl ps -a --name kube-scheduler -q | head -1) 2>&1 | tail -10'
docker exec devops-control-plane grep kubeconfig /etc/kubernetes/manifests/kube-scheduler.yaml
```

```
stat /etc/kubernetes/scheduler-typo.conf: no such file or directory
```

**Fix:**

```bash
docker exec devops-control-plane sed -i 's|scheduler-typo.conf|scheduler.conf|' \
  /etc/kubernetes/manifests/kube-scheduler.yaml
```

The kubelet restarts the static pod within seconds, and **the Pending pods
schedule themselves** — nothing needs recreating.

**The general lesson: "no events" is a positive signal, not an absence of
information.** It is the difference between "a scheduler refused this" and "no
scheduler exists".

### Scenario 5 — the controller manager cannot start

**What was done:** `--kubeconfig` in `kube-controller-manager.yaml` points at
`cm-typo.conf`.

| | |
|---|---|
| **Blast radius** | **everything** -- but nothing visibly fails |
| **Domain** | **control plane** |
| **Layer** | control plane |
| **Symptom** | `kubectl scale` reports success and **nothing happens** |

**Diagnosis:**

```bash
kubectl -n cka31 scale deployment web --replicas=6
kubectl -n cka31 get deploy web
```

```
NAME   READY   UP-TO-DATE   AVAILABLE
web    3/6     3            3
```

**Desired 6, actual 3, and it never changes.** The API server accepted the write;
nothing acted on it.

```bash
kubectl -n cka31 get rs                      # no new ReplicaSet
kubectl -n kube-system get pods | grep controller-manager
kubectl -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}{"  renewed="}{.spec.renewTime}{"\n"}'
```

**A lease whose `renewTime` is stale is a dead giveaway**
([CKA 26](../../26-cluster-design-and-ha/)) — the holder is not heartbeating.

```bash
docker exec devops-control-plane sh -c \
  'crictl logs --previous $(crictl ps -a --name kube-controller-manager -q | head -1) 2>&1 | tail -10'
docker exec devops-control-plane grep kubeconfig /etc/kubernetes/manifests/kube-controller-manager.yaml
```

**Fix:**

```bash
docker exec devops-control-plane sed -i 's|cm-typo.conf|controller-manager.conf|' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
```

**This is the most dangerous scenario in the set, because nothing looks wrong.**
`kubectl` works, every pod is `Running`, every node is `Ready`, and the only
symptom is that changes have no effect. Also silently stopped: endpoint updates,
node lifecycle, PV binding, ServiceAccount token cleanup, certificate approval —
**every controller lives in that one binary.**

**How you would notice in production:** a Deployment that "did not roll out", or a
Service whose endpoints never removed a deleted pod. Both look like application
bugs.

### Scenario 6 — the kubelet is stopped on a worker

**What was done:** `systemctl stop kubelet` on `devops-worker2`.

| | |
|---|---|
| **Blast radius** | one node |
| **Domain** | **node** |
| **Layer** | Node |
| **Symptom** | `NotReady` after ~40s; that node's pods eventually go `Terminating` or `Unknown` |

**Diagnosis:**

```bash
kubectl get nodes
```

```
NAME              STATUS     ROLES
devops-worker2    NotReady   <none>
```

```bash
kubectl describe node devops-worker2 | grep -A10 Conditions
```

```
Ready   Unknown   NodeStatusUnknown   Kubelet stopped posting node status.
```

**`Unknown`, not `False`** (31.5). The kubelet is not reporting at all, so there
is nothing to read from `kubectl` — **you must get onto the machine**:

```bash
docker exec devops-worker2 systemctl status kubelet
docker exec devops-worker2 journalctl -u kubelet -n 30 --no-pager
docker exec devops-worker2 crictl ps          # the CONTAINERS are still running
```

**That last command is the important one.** The workload containers are still up
and serving traffic — the kubelet manages them, it does not proxy for them. **A
`NotReady` node is often still serving requests**, which is why this can go
unnoticed.

**Fix:**

```bash
docker exec devops-worker2 systemctl start kubelet
kubectl get nodes -w
```

**What to check when it is not this simple:** the journal will name it — a cgroup
driver mismatch ([CKA 27](../../27-build-a-cluster-with-kubeadm/)), swap
re-enabled after a reboot, a full disk, or an expired client certificate
([CKA 13](../../13-tls-in-kubernetes/)):

```bash
docker exec devops-worker2 sh -c \
  'openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates'
```

### Scenario 7 — cordoned and tainted

**What was done:** `kubectl cordon devops-worker2` plus a
`maintenance=inprogress:NoSchedule` taint.

| | |
|---|---|
| **Blast radius** | one node's *scheduling* |
| **Domain** | node -- but **not a failure** |
| **Layer** | Node |
| **Symptom** | new pods never land on that node; existing ones are untouched |

**Diagnosis:**

```bash
kubectl get nodes
```

```
NAME              STATUS                     ROLES
devops-worker2    Ready,SchedulingDisabled   <none>
```

**`Ready,SchedulingDisabled` is the whole answer** — and it is in the output of
the very first orientation command (31.2).

```bash
kubectl describe node devops-worker2 | grep -iA3 taint
kubectl -n cka31 scale deployment web --replicas=9
kubectl -n cka31 get pods -o wide            # all on control-plane and worker
kubectl -n cka31 describe pod <pending> | grep -A5 Events
```

```
0/3 nodes are available: 1 node(s) had untolerated taint {maintenance: inprogress},
1 node(s) were unschedulable, ...
```

**Note there ARE events here**, and they name both mechanisms — unlike scenario
4's silence (31.7).

**Fix:**

```bash
kubectl uncordon devops-worker2
kubectl taint node devops-worker2 maintenance-
```

**This one is included because it is not a fault.** Somebody drained that node
for maintenance and did not put it back — a completely normal thing to happen,
which presents as "we ran out of capacity" and is fixed in two commands. **Check
`kubectl get nodes` for `SchedulingDisabled` before investigating anything about
scheduling.**

### Scenario 8 — cluster DNS has no backends

**What was done:** `kubectl -n kube-system scale deployment coredns --replicas=0`.

| | |
|---|---|
| **Blast radius** | **everything that resolves a name** |
| **Domain** | **network** |
| **Layer** | below Service, above Pod |
| **Symptom** | connections by **name** fail; connections by **IP** work |

**Diagnosis:**

```bash
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "%{http_code}\n" http://web
kubectl -n cka31 exec client -- curl -s -m5 http://web 2>&1 | tail -1
```

```
curl: (6) Could not resolve host: web
```

**"Could not resolve" is not a connectivity error** — it is DNS, and it points at
one place. Confirm by bypassing it (31.6):

```bash
SVC=$(kubectl -n cka31 get svc web -o jsonpath='{.spec.clusterIP}')
kubectl -n cka31 exec client -- curl -s -m5 -o /dev/null -w "by IP: %{http_code}\n" "http://$SVC"
```

```
by IP: 200
```

**Works by IP, fails by name.** That two-command comparison is the entire
diagnosis ([CKA 24](../../24-dns-and-coredns/)).

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns      # none
kubectl -n kube-system get endpoints kube-dns            # <none>
kubectl -n kube-system get deployment coredns            # 0/0
```

**Fix:**

```bash
kubectl -n kube-system scale deployment coredns --replicas=2
```

**Note the failure mode:** `connection refused` from `10.96.0.10`, instantly, not
a timeout — because a Service with no endpoints gets a `REJECT` rule
([CKA 23](../../23-service-networking/)). **The same signal as scenario 1, one
layer down**, which is a good illustration that the *shape* of a failure
generalises even when the object does not.

---

## Challenge answers

### C1 - Triage from a one-line report

**1. "The website is down."**

```bash
kubectl get pods -n <ns> -o wide     # is the workload up at all?
kubectl get endpoints -n <ns>        # does the Service have backends?
kubectl get ingress -n <ns>          # does it have an ADDRESS?
```

Eliminates, in order: the pods, the Service wiring, and the ingress path. **If
all three are healthy the fault is above Kubernetes** — DNS outside the cluster,
a load balancer, or a firewall — and that is worth establishing in thirty seconds
rather than an hour.

**2. "Deploys aren't going out."**

```bash
kubectl -n kube-system get pods | grep controller-manager
kubectl get deploy -n <ns>                    # desired vs available
kubectl get rs -n <ns> --sort-by=.metadata.creationTimestamp | tail -3
```

**"Nothing changes" is the control-plane signature** (31.4). The first command
tests the most likely cause; the second and third distinguish "nothing was
created" (controller manager) from "created and cannot schedule" (scheduler,
resources, or the image).

**3. "Half our requests are failing."**

```bash
kubectl get pods -n <ns> -o wide              # are SOME pods unhealthy?
kubectl get endpoints -n <ns> <svc>           # how many backends?
kubectl get nodes                             # is one node unhealthy?
```

**"Half" or "some" means a subset**, so the question is *which* subset — and the
three usual axes are per-pod, per-node and per-endpoint. Comparing the pod list
against the endpoint list answers it fastest (C2).

**4. "The cluster is slow."**

```bash
kubectl top nodes                              # resource pressure
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl -n kube-system get pods | grep -v Running
```

**"Slow" is the least informative report you get**, so the first job is to make
it specific: slow to schedule, slow to respond, or slow inside the application.
`kubectl top` and events answer the first two; anything else is the application's
own telemetry, not Kubernetes'.

Add a fourth if the API itself feels slow:
`kubectl get --raw='/metrics' | grep apiserver_request_duration`.

**5. "I can't `kubectl`."**

```bash
kubectl version                                # client works? server reachable?
kubectl config current-context                 # the right cluster?
kubectl get --raw=/readyz
```

**Check your own side first.** The most common causes are a wrong context, an
expired client certificate ([CKA 13](../../13-tls-in-kubernetes/)), and a
kubeconfig pointing at the wrong endpoint — all of which look identical to "the
cluster is down".

If the API server really is unreachable, the next commands are on the node:
`crictl ps -a | grep apiserver` and the kubelet journal (31.4).

### C2 - Two pods, one symptom

**Five causes, and the confirming command for each:**

| Cause | Command |
|---|---|
| **Both are on one unhealthy node** | `kubectl get pods -o wide` -- do the failures share a `NODE`? |
| **They are not in the Service's endpoints** | `kubectl get endpoints <svc> -o yaml` -- compare against the pod IPs |
| **They failed a readiness probe** | `kubectl get pods` -- `1/1` versus `0/1` |
| **A node-local dependency differs** | a hostPath volume, a DaemonSet that is not running there, node-local DNS |
| **They are an older ReplicaSet** | `kubectl get rs` -- a rollout that stalled halfway |

**The single command that narrows it fastest:**

```bash
kubectl get pods -n <ns> -o wide
```

**Because it shows READY, STATUS, RESTARTS and NODE together.** In one screen you
learn whether the two failures share a node (node domain), share a readiness
state (application), or share nothing (endpoints or rollout). Every other command
in that table is a follow-up to what this one shows.

The second-fastest is `kubectl get endpoints`, because "the pod is healthy and
not receiving traffic" and "the pod is receiving traffic and failing" are
completely different investigations, and the endpoint list separates them.

### C3 - Nothing is happening

**1. The domain: control plane — and the sentence gives it away twice.**

`kubectl` works, so the API server is fine. `kubectl get deploy` shows the
desired count, so **the write was accepted and stored** — the object in etcd says
10. Something is meant to notice that and act, and it has not.

**"The desired state is recorded and reality does not move" is the definition of
a controller failure** (31.4).

**2. The component: kube-controller-manager.**

The Deployment controller lives there, and it is what creates and scales
ReplicaSets.

**Why not the others:**

- **Not the API server** — `kubectl` works and the object was updated.
- **Not the scheduler** — a scheduler failure produces `Pending` **pods**. Here
  there are no new pods at all, so the ReplicaSet was never scaled and nothing
  ever asked the scheduler for anything.
- **Not etcd** — the write succeeded and reads are consistent.

**The distinction between 2 and 3 is worth stating precisely: no new pods at all
means the controller manager; new pods stuck `Pending` means the scheduler.**

**3. The commands, in order:**

```bash
# 1. did a ReplicaSet even get scaled?
kubectl get rs -n <ns>
kubectl describe deploy web -n <ns> | grep -A5 Events

# 2. is the controller manager running?
kubectl -n kube-system get pods | grep controller-manager

# 3. is it actually working, or just running?
kubectl -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}{"  renewed="}{.spec.renewTime}{"\n"}'

# 4. why not?
kubectl -n kube-system logs kube-controller-manager-<node> --tail=30
docker exec <cp> sh -c 'crictl logs --previous $(crictl ps -a --name kube-controller-manager -q | head -1) 2>&1 | tail -20'
docker exec <cp> cat /etc/kubernetes/manifests/kube-controller-manager.yaml
```

**Step 3 is the one people skip.** A `Running` pod is not a working controller —
the process can be up and failing to acquire or renew its lease
([CKA 26](../../26-cluster-design-and-ha/)). **A stale `renewTime` proves it is
not doing its job** even when the pod looks perfect.

**4. What else is silently broken.**

**Every controller in that binary**, which is most of them:

- **Endpoints and EndpointSlices** are not updated — a deleted pod stays in the
  rotation and a new one never joins ([CKA 23](../../23-service-networking/)).
- **Node lifecycle** — a failed node is never marked `NotReady`, and its pods are
  never evicted or rescheduled.
- **PersistentVolume binding** — new PVCs stay `Pending` forever
  ([CKA 20](../../20-storage-internals-and-csi/)).
- **ServiceAccount and token controllers** — new namespaces get no `default`
  ServiceAccount ([CKA 16](../../16-service-accounts/)).
- **CSR approval** — a node trying to join or rotate its certificate is never
  approved ([CKA 27](../../27-build-a-cluster-with-kubeadm/)).
- **Job and CronJob controllers**, garbage collection, namespace deletion —
  namespaces stick in `Terminating`.

**Nothing in that list produces an alert on its own**, which is why this failure
is usually discovered by its second or third symptom rather than its first. **The
useful monitor is not "is the pod Running" but "is the lease being renewed".**

### C4 - `Unknown` versus `NotReady`

**`Ready: False`** — **the kubelet is alive and reporting a problem.**

It is talking to the API server, it has evaluated its own health, and it has
decided it is not fit to run pods. **The reason field tells you what is wrong:**

```
KubeletNotReady          container runtime network not ready: NetworkPluginNotReady
KubeletNotReady          container runtime is down
KubeletHasDiskPressure   ...
```

```bash
kubectl describe node NODE | grep -A10 Conditions
```

**The fault is inside the node's stack** — usually the CNI
([CKA 22](../../22-pod-networking-and-cni/)) or the container runtime — and
`kubectl` alone often names it.

**`Ready: Unknown`** — **the kubelet is not reporting at all.**

Nobody has said the node is unhealthy. The **node controller** noticed that no
heartbeat arrived for ~40 seconds and marked every condition `Unknown` on the
node's behalf:

```
Ready   Unknown   NodeStatusUnknown   Kubelet stopped posting node status.
```

```bash
kubectl describe node NODE | grep -E "LastHeartbeatTime|Unknown"
```

**`LastHeartbeatTime` is the most useful field**: it dates the failure, which
usually identifies it. A heartbeat that stopped at a deploy, a reboot, or
midnight is most of the diagnosis.

**Why `Unknown` is worse to diagnose:**

**The machine has stopped telling you anything, so the API server has no
information to give you.** With `Ready: False` the kubelet is an active witness;
with `Unknown` you have only its silence, and silence is consistent with:

- the kubelet process is dead or crash-looping
- the machine is powered off, or the VM was deleted
- the network path to the API server is broken
- the kubelet's client certificate expired
  ([CKA 13](../../13-tls-in-kubernetes/)) -- **it runs perfectly and cannot
  authenticate**
- the node's clock drifted far enough to break TLS

**All five look identical from `kubectl`.** And the containers may still be
running and serving traffic throughout, so the application does not tell you
either.

**Commands for each:**

```bash
# Ready: False -- ask the node, via the API
kubectl describe node NODE | grep -A10 Conditions
kubectl get events -A --field-selector involvedObject.name=NODE
kubectl -n kube-system get pods -o wide | grep NODE     # is its CNI pod healthy?

# Ready: Unknown -- you must reach the machine
ssh NODE systemctl status kubelet
ssh NODE journalctl -u kubelet -n 50 --no-pager
ssh NODE crictl ps                                       # are containers still up?
ssh NODE openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates
ssh NODE df -h /var/lib/kubelet
```

**The one you cannot answer from `kubectl` alone is `Unknown`.** By definition
the source of truth has stopped reporting, so every remaining question is
answerable only on the machine. **`False` is a `kubectl` problem and `Unknown` is
an SSH problem** — knowing which you have before you start saves the first ten
minutes.

### C5 - Write the runbook

```
=============================================================================
KUBERNETES TRIAGE -- first 5 commands
=============================================================================
Do these THREE first, always. Do not skip to the thing you suspect.

  1  kubectl get nodes
  2  kubectl -n kube-system get pods
  3  kubectl get pods -A | grep -v Running

-----------------------------------------------------------------------------
ROUTE ON WHAT THEY SHOWED
-----------------------------------------------------------------------------
A node NotReady / Unknown ................................... NODE
  -> kubectl describe node NODE | grep -A10 Conditions
     False   = kubelet is alive and complaining. Read the reason.
     Unknown = kubelet is silent. GET ON THE MACHINE:
               systemctl status kubelet ; journalctl -u kubelet -n50
  Cordoned / SchedulingDisabled is NOT a fault -- someone drained it.

A kube-system pod not Running ............................... CONTROL PLANE
  -> kubectl -n kube-system logs <pod>
  -> if kubectl itself is dead, on the control-plane node:
       crictl ps -a | grep -E 'apiserver|scheduler|controller|etcd'
       crictl logs --previous <id>
       journalctl -u kubelet -n 40

All healthy above, one workload broken ...................... APPLICATION
  -> kubectl get endpoints SVC          <-- START HERE. Empty means:
        selector mismatch | pods not Ready | no pods
  -> kubectl describe pod POD | tail -20
  -> kubectl logs POD --previous        <-- for anything crash-looping

All healthy and traffic still fails ......................... NETWORK
  -> by pod IP?      works => CNI ok
  -> by ClusterIP?   works => kube-proxy ok
  -> by name?        fails => DNS: kubectl -n kube-system get endpoints kube-dns

-----------------------------------------------------------------------------
READ THE FAILURE. IT IS TELLING YOU SOMETHING.
-----------------------------------------------------------------------------
  refused INSTANTLY ....... something answered "no" (no endpoints / REJECT)
  TIMEOUT ................. packet left, nothing came back (route/policy/dead)
  Pending + events ........ a scheduler looked and refused -- read the event
  Pending + NO events ..... nothing is watching -> SCHEDULER IS DOWN
  ImagePullBackOff ........ networking and scheduling WORKED. It is the image.
  Running 0/1 ............. readiness probe. The app, not the cluster.
  Unknown / Evicted ....... the NODE.
  Nothing changes at all .. CONTROLLER MANAGER.

-----------------------------------------------------------------------------
BEFORE YOU ESCALATE
-----------------------------------------------------------------------------
  kubectl get events -A --sort-by=.lastTimestamp | tail -30   (expire in ~1h!)
  What changed in the last hour? deploy / upgrade / reboot / cert expiry
=============================================================================
```

**What I left out, and why:**

- **etcd troubleshooting.** If etcd is broken the API server is down and this
  runbook's first command already fails -- that is a different, escalate-now
  procedure, not first-response triage.
- **Ingress-controller specifics.** They vary by controller and belong in the
  runbook for whichever one you run; nginx annotations would be wrong for half
  the readers.
- **Anything needing more than one line of `crictl`.** Someone six months in
  should know it exists and where to look; deeper than that is where you call
  for help.
- **Performance and resource tuning.** "Slow" is a different investigation from
  "broken", and mixing them makes both worse.
- **Every command's flags.** It has to fit on one screen or it will not be read
  at 3am. **A runbook that is skimmed and followed beats a complete one that is
  closed.**

**The one thing I would not cut is the failure-string table.** Turning "refused
versus timeout" and "events versus no events" into reflexes is what actually
makes someone fast, and neither is obvious.

---

## Files

| File | Purpose |
|---|---|
| `app.yaml` | a two-tier application plus a client pod, so every check is one command |
| `break.sh` | eight scenarios, applied **without saying which**; `random` picks one blind |
| `restore.sh` | undoes what is recorded, or `all` for an unknown state (idempotent) |
| `verify.sh` | confirms a healthy baseline -- it checks that **nothing** is broken |

`break.sh` records the active scenario in `solution/.broken`, which is
gitignored. **Reading it is the one thing that spoils the exercise.**

---

## On `verify.sh` being different

Every other assignment's `verify.sh` checks that something was built. This one
checks that **nothing is broken** -- nodes Ready and schedulable, control-plane
pods running, leases being renewed, DNS with endpoints, the application reachable
end to end.

Two of its checks are worth stealing for a real cluster, because they test
*behaviour* rather than *status*:

```bash
# does the scheduler actually schedule?
kubectl run probe --image=busybox:1.36 --restart=Never -- sleep 60
kubectl get pod probe -o jsonpath='{.spec.nodeName}'      # empty == not scheduled

# does the controller manager actually reconcile?
kubectl create deployment probe-d --image=busybox:1.36 -- sleep 60
kubectl get rs -l app=probe-d                              # none == not reconciling
```

**Both catch scenarios 4 and 5, which a `Running` status does not.** A pod that
is `Running` proves a process started; only a *scheduled* pod proves the
scheduler works.
