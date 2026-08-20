# CKA 10 — Multi-Container Pods, Init Containers and Sidecars

**Time:** 60-75 minutes
**Prerequisites:** [Day 02](../../days/day-02-kubectl-and-your-first-pod/), [Day 13](../../days/day-13-health-probes/), [Day 14](../../days/day-14-volumes-pv-pvc/)
**Source lectures:** 114, 115, 119

Every pod you have built so far held one container. `spec.containers` has always
been an array — this assignment is about why.

---

## Part 1 - Concepts

### 10.1 What containers in a pod actually share

Three things, and they are the entire reason the pattern exists:

| Shared | Consequence |
|---|---|
| **Lifecycle** | created together, destroyed together, scheduled to one node |
| **Network namespace** | one IP, one port range. They reach each other on **`localhost`** |
| **Volumes** | an `emptyDir` mounted into both is the same directory |

What they do **not** share is a filesystem root or a process namespace. Each
container still has its own image, its own `/`, and its own PID 1 — unless you
opt in with `shareProcessNamespace: true`.

**One IP means one port range.** Two containers in a pod cannot both bind
`:8080`. This catches people who copy a sidecar in without reading its ports.

### 10.2 The reason this exists

You have a web server and an application that must be paired one-to-one, scale
together, and be deployed together — but whose code you do not want to merge.
Two Deployments plus a Service would give you `N` of one and `M` of the other,
connected over the network, with no guarantee any pair is co-located.

A pod gives you exactly the pairing: **one of each, on one node, sharing a
loopback interface and a directory.**

The test for whether something belongs in the same pod: *would it ever make
sense to scale these two independently?* If yes, they are two Deployments. If
no — a log shipper, a config reloader, a proxy dedicated to this instance — it
is a second container.

### 10.3 Three patterns, and the ordering problem

```
CO-LOCATED           |  A ==================>
(plain containers)   |  B ==================>
                     |  no defined start order

INIT CONTAINERS      |  I1 ====>
                     |          I2 ====>
                     |                   APP =========>
                     |  sequential, each to completion, then the app

SIDECAR              |  S  =====================================>
(init + restart:     |       APP =========================>
 Always)             |  starts BEFORE the app, ends AFTER it
```

**Co-located containers** are the original form: two entries in
`spec.containers`. Both run for the pod's life. **There is no way to say which
starts first** — they are elements of an array, and the array order is not a
startup guarantee. If your two containers genuinely do not care, this is the
right and simplest choice.

**Init containers** run **before** any regular container, **sequentially**, each
to completion. The next one starts only when the previous exits `0`. If one
fails, the pod restarts it according to the pod's `restartPolicy` and the app
never starts. Use for setup that must *finish*: waiting for a database, running
a migration, fetching a config file, fixing volume permissions.

**Sidecar containers** are an init container with **`restartPolicy: Always`**.
That one field changes everything: instead of running to completion, it starts,
becomes ready, and **keeps running** while the app runs — and it is terminated
*after* the app container. That ordering is precisely what a log shipper needs:
it must be up in time to catch the app's first log line, and still up to catch
the last one.

### 10.4 Why sidecars are init containers

This is the part that looks strange and is worth understanding.

Before Kubernetes 1.28, a "sidecar" was just a second entry in
`spec.containers`, and it had two chronic problems:

- **No startup ordering.** The log shipper might come up after the app had
  already logged and crashed.
- **No shutdown ordering.** On pod termination all containers get SIGTERM at
  once, so the shipper often died before flushing the app's final logs. Worse,
  in a Job, a never-exiting sidecar kept the pod `Running` forever because the
  Job waited for *all* containers to exit.

Putting the sidecar in `initContainers` with `restartPolicy: Always` fixes both:
the init sequence guarantees it starts first, and the kubelet knows to stop it
last. It also stops sidecars from keeping Jobs alive.

```yaml
spec:
  initContainers:
    - name: log-shipper
      image: busybox:1.36
      restartPolicy: Always        # <- this single field makes it a sidecar
      command: ["sh", "-c", "tail -F /var/log/app/out.log"]
  containers:
    - name: app
      image: busybox:1.36
```

**`restartPolicy` on an init container may only be `Always`.** It is not a
general-purpose field; it is the flag that says "this one does not terminate".

> Available since **1.29** (beta, on by default) and GA in **1.33**. On older
> clusters you fall back to a plain second container and live with the ordering
> problem.

### 10.5 Reading the status

```
NAME     READY   STATUS            RESTARTS   AGE
purple   0/1     Init:0/2          0          8s
purple   0/1     Init:1/2          0          15s
purple   1/1     Running           0          31s
```

`Init:1/2` means one init container finished and the second is running. Two
STATUS values matter:

| STATUS | Meaning |
|---|---|
| `Init:0/2` | the **first** init container is still running |
| `Init:Error` | an init container exited non-zero |
| `Init:CrashLoopBackOff` | an init container keeps failing and is being backed off |
| `PodInitializing` | init is done, the app containers are starting |

**The `READY` column counts regular containers only.** A pod with two init
containers and one app container shows `1/1` when healthy — the init containers
were never in that denominator. Their state lives in a separate field:

```bash
kubectl get pod X -o jsonpath='{.status.initContainerStatuses[*].name}'
kubectl get pod X -o jsonpath='{.status.containerStatuses[*].name}'
```

Run both in the lab and see which list your sidecar appears in. That is the
answer to "why does `kubectl get pods` not show it".

### 10.6 Debugging a multi-container pod

**`kubectl logs` needs to be told which container**, and that is the single most
common stumbling block:

```bash
kubectl logs POD                  # error: a container name must be specified
kubectl logs POD -c app
kubectl logs POD -c init-db       # init containers too -- this is how you see WHY init failed
kubectl logs POD --all-containers=true
kubectl exec -it POD -c app -- sh
```

**When a pod is stuck in `Init:`, `kubectl logs POD` is useless** — it defaults
to the app container, which has not started. You must name the init container.

Exit codes worth recognising:

| Code | Means |
|---|---|
| `0` | completed — `Reason: Completed` |
| `1` | the program failed — read its logs |
| `127` | **command not found** — a typo in `command:`, or the binary is not in that image |
| `137` | SIGKILL — usually OOM |

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka10
kubectl config set-context --current --namespace=cka10
```

### Step 1: Co-located containers, sharing a volume and localhost

```bash
kubectl apply -f solution/01-colocated.yaml
kubectl get pod colocated -w        # 0/2 -> 2/2, Ctrl-C when Running
```

`2/2` — **two containers, one pod, one IP.**

```bash
kubectl get pod colocated -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pod colocated -o jsonpath='{.spec.containers[*].name}{"\n"}'
```

Prove the shared volume: the `writer` container wrote a file, and `nginx` is
serving it:

```bash
kubectl exec colocated -c writer -- cat /data/index.html
kubectl exec colocated -c web    -- cat /usr/share/nginx/html/index.html
```

**Same bytes, two different paths, two different images.** Neither container
knows the other exists; they agreed on a volume.

Prove the shared network — from inside the *writer*, fetch the *web* container:

```bash
kubectl exec colocated -c writer -- wget -qO- http://localhost:80
```

`localhost` reached a different container. There is no Service here and no DNS
lookup — they are in one network namespace.

```bash
kubectl exec colocated -c web -- sh -c 'wget -qO- http://localhost:80; echo'
```

Same result from the other side. **This is what "pod" means.**

### Step 2: Init containers run in order, to completion

```bash
kubectl apply -f solution/02-init-sequential.yaml
kubectl get pod sequential-init -w
```

```
NAME              READY   STATUS            RESTARTS   AGE
sequential-init   0/1     Init:0/2          0          2s
sequential-init   0/1     Init:1/2          0          12s
sequential-init   0/1     PodInitializing   0          22s
sequential-init   1/1     Running           0          23s
```

Ctrl-C. Now read the timeline in order:

```bash
kubectl logs sequential-init -c step-one
kubectl logs sequential-init -c step-two
kubectl logs sequential-init -c app
```

The app's timestamp is roughly 20 seconds after the pod was created — the sum of
both init containers. **They ran one after the other, not in parallel.**

Now the counting question from 10.5:

```bash
kubectl get pod sequential-init
kubectl get pod sequential-init -o jsonpath='{.status.initContainerStatuses[*].name}{"\n"}'
kubectl get pod sequential-init -o jsonpath='{.status.containerStatuses[*].name}{"\n"}'
```

`READY 1/1`, yet three containers ran. **Init containers are not in that
denominator** — they are in a separate status list.

### Step 3: An init container that waits for a dependency

This is the pattern you will actually use.

```bash
kubectl apply -f solution/03-init-wait-for-service.yaml
kubectl get pod waits-for-db
kubectl logs waits-for-db -c wait-for-db
```

```
waiting for the database service to resolve...
  still no DNS record for database
  still no DNS record for database
```

It will sit at `Init:0/1` indefinitely. That is the design: **the app is not
allowed to start against a dependency that is not there.**

Try the mistake first:

```bash
kubectl logs waits-for-db
```

```
Error from server (BadRequest): container "app" in pod "waits-for-db" is waiting
to start: PodInitializing
```

**`kubectl logs` with no `-c` targets the app container, which does not exist
yet.** Remember this; it is the most common wasted minute in a real incident.

Now release it:

```bash
kubectl apply -f solution/04-database-service.yaml
kubectl get pod waits-for-db -w        # Init:0/1 -> Running within ~5s
kubectl logs waits-for-db -c wait-for-db --tail=3
kubectl logs waits-for-db -c app
```

Note what was sufficient: **a Service object, with no pods behind it.** A
Service gets its DNS record from CoreDNS as soon as it exists. If the app needs
a *working* database, not merely a resolvable name, the init container must test
the port — `nc -z database 5432` — not the name. That distinction is the
difference between a check that works and one that only looks like it does.

### Step 4: A native sidecar

```bash
kubectl apply -f solution/05-native-sidecar.yaml
kubectl get pod with-sidecar -w
```

Watch carefully:

```
with-sidecar   0/1   Init:0/1        0     2s
with-sidecar   1/1   Running         0     5s
...
with-sidecar   0/1   Completed       0     40s
```

The sidecar goes through `Init:0/1` — it is an init container — but the pod then
becomes `Running` **while the sidecar is still running**, which a normal init
container never does.

```bash
kubectl logs with-sidecar -c log-shipper
```

```
[shipper] up at 14:22:03 -- before the app
[shipped] [app] started at 14:22:05
[shipped] [app] tick 0 at 14:22:05
...
[shipped] [app] finished
```

**Read the two timestamps.** The shipper's own start line is *earlier* than the
app's first line — so the app's very first log was shipped. That is the
guarantee, and it is the whole point.

Now the other half:

```bash
kubectl get pod with-sidecar
```

`Completed`. **The pod finished even though the sidecar's `tail -F` would never
exit on its own.** The kubelet stopped it once the app container terminated.

Compare with the old way:

```bash
kubectl apply -f solution/06-colocated-race.yaml
sleep 12
kubectl logs colocated-race -c log-shipper
```

```
[shipper] up at 14:25:11
```

**The app's `FIRST LINE` is missing.** The shipper attached to the file five
seconds late and `tail -f` only reports what arrives *after* it attaches. The
line exists on disk:

```bash
kubectl exec colocated-race -c app -- cat /var/log/app/out.log
```

It was simply never shipped. This is not a contrived failure — it is the
ordinary behaviour of a log sidecar with no startup ordering, and it is why
`restartPolicy: Always` on an init container was added to the API.

```bash
kubectl delete pod colocated-race --grace-period=1
```

### Step 5: Debug a broken init container

```bash
kubectl apply -f solution/07-broken-init-BAD.yaml
sleep 20
kubectl get pod orange
```

```
NAME     READY   STATUS                  RESTARTS   AGE
orange   0/1     Init:CrashLoopBackOff    2          20s
```

Work it out in the order you would in an exam:

```bash
# 1. WHICH container, and what did it do?
kubectl describe pod orange | sed -n '/Init Containers:/,/^Containers:/p'
```

```
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    127
```

**Exit code 127 is "command not found"** (10.6) — so this is not an application
failure, it is a wrong command or a binary missing from the image.

```bash
# 2. what did it say?
kubectl logs orange -c init-my-service
```

```
exec: "slep": executable file not found in $PATH
```

```bash
# 3. what was it asked to run?
kubectl get pod orange -o jsonpath='{.spec.initContainers[0].command}{"\n"}'
```

```
["slep","20"]
```

There it is. Now fix it — and remember from [CKA 04](../04-imperative-declarative-and-apply/)
that most of a pod spec is **immutable**:

```bash
kubectl edit pod orange      # change slep -> sleep, then save
```

```
error: pods "orange" is invalid ... spec: Forbidden: pod updates may not change
fields other than `spec.containers[*].image` ...
```

`kubectl edit` writes your attempt to a temp file and tells you the path. The
working route:

```bash
sed 's/"slep"/"sleep"/' solution/07-broken-init-BAD.yaml | kubectl replace --force -f -
kubectl get pod orange -w
```

`--force` deletes and recreates. **The pod's identity survives; the pod does
not.** For anything managed by a Deployment you would edit the template instead
and let the rollout handle it.

### Cleanup

```bash
kubectl delete namespace cka10 --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Choose the pattern

For each, say which of the three patterns you would use and why in one sentence:

1. A metrics exporter that scrapes the app on `localhost:9000` and exposes
   Prometheus format on `:9100`.
2. A schema migration that must complete before the app accepts traffic.
3. A container that fetches TLS certificates into a shared volume every 12
   hours.
4. A `chown` of a mounted volume that the app cannot perform because it runs as
   a non-root user.
5. A Redis cache used by three different Deployments.

One of these is a trick — say which and why.

### C2 - Stuck at Init:0/3

A pod has been at `Init:0/3` for twenty minutes. Write the exact command
sequence to determine which init container is stuck, what it is waiting for, and
whether it is failing or merely slow. Then say how the answer would differ if
the status were `Init:2/3`.

### C3 - Sidecar failure modes

Answer precisely:

1. A **native sidecar** crashes while the app is running. What happens to the
   pod?
2. A plain **init container** exits `1`. What happens, and does the app ever
   start?
3. The **app** container in a pod with a native sidecar exits `0`, with pod
   `restartPolicy: Never`. What happens to the sidecar?
4. Why can `restartPolicy` on an init container only be `Always`?

### C4 - Write the wait correctly

Write an init container that waits until a Postgres Service is **actually
accepting connections**, not merely resolvable — and that gives up after 2
minutes rather than hanging forever. Use only `busybox`. State why the timeout
matters and what the pod does when it expires.

### C5 - Two containers, one port

A colleague adds a sidecar to a pod and the pod now crash-loops with the app
container reporting `bind: address already in use`, even though the sidecar's
`containerPort` is different from the app's. Explain what actually happened,
and give the two commands that would confirm it.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the co-located pod has 2/2 ready and shares both a volume and localhost;
init containers ran sequentially in the right order; the waiting pod only
started after the Service existed; the sidecar's first log line precedes the
app's; the broken pod was fixed and is Running.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# generate a two-container pod skeleton fast
kubectl run web --image=nginx:alpine --dry-run=client -o yaml > p.yaml
# ...then add the second entry under spec.containers by hand

# logs and exec always need -c on a multi-container pod
kubectl logs POD -c NAME
kubectl logs POD --all-containers=true --prefix
kubectl logs POD -c NAME --previous          # the crashed instance
kubectl exec -it POD -c NAME -- sh

# what containers does this pod have, of each kind?
kubectl get pod POD -o jsonpath='{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}'

# just the init container section of describe
kubectl describe pod POD | sed -n '/Init Containers:/,/^Containers:/p'

# find every pod in the cluster with more than one container
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers | length > 1) | .metadata.name'
```

**Traps**

- **`kubectl logs POD` fails on a multi-container pod** — `a container name must
  be specified`. Always pass `-c`.
- **A pod stuck in `Init:` has no app logs.** Name the init container.
- **`READY 1/1` does not mean one container ran.** Init containers are excluded
  from that count.
- **Init containers are sequential; regular containers are not ordered at all.**
  If a task says "must start first", the answer is an init container or a
  sidecar, never array order.
- **A sidecar is `initContainers` + `restartPolicy: Always`**, and `Always` is
  the only legal value there.
- **One IP per pod** — two containers cannot bind the same port.
- **Most of a pod spec is immutable.** `kubectl edit` will refuse; use
  `kubectl replace --force -f`.
- **`emptyDir` dies with the pod.** It is for sharing between containers, not
  for persistence — that is [Day 14](../../days/day-14-volumes-pv-pvc/).
- **Exit 127 = command not found**, not an application bug.
- A Service resolves in DNS **before it has any endpoints**, so an init
  container that only does `nslookup` proves less than it appears to.

---

**Previous:** [CKA 09 — Encrypting Secret Data at Rest](../09-encryption-at-rest/)
**Next:** [CKA 11 — Autoscaling: In-Place Resize and the Vertical Pod Autoscaler](../11-autoscaling-vpa-inplace/)
