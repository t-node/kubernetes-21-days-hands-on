# Day 21 — Break & Fix

**Time:** 90-120 minutes
**Prerequisites:** Days 01-20

No new concepts today. Eight broken clusters, a stopwatch, and the debugging
method that makes the previous twenty days usable under pressure.

This is the day that most resembles a real on-call shift, and the closest thing
in this course to a live interview exercise.

---

## Part 1 - The method

### 21.1 The four questions, always in this order

Resist the urge to guess. Work down the stack:

```
1. Is the POD running?           kubectl get pods
                                 Pending / CrashLoop / ImagePull / OOMKilled?
        |
2. Is the POD ready?             kubectl get pods   (the READY column)
                                 a failing readiness probe is invisible in STATUS
        |
3. Can the SERVICE find it?      kubectl get endpoints <svc>
                                 <none> means selector or readiness
        |
4. Can the CLIENT reach it?      test from inside the cluster, then outside
                                 DNS, ports, NetworkPolicy, Ingress rules
```

Most incidents resolve at step 1 or 3. Do not start at step 4 because that is
where the user's complaint arrived.

### 21.2 The five commands that solve most problems

```bash
kubectl get pods -n <ns> -o wide            # the shape of the problem
kubectl describe pod <pod> -n <ns>          # READ THE EVENTS AT THE BOTTOM
kubectl logs <pod> -n <ns> --previous       # why the last container died
kubectl get endpoints <svc> -n <ns>         # is the Service wired up
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20
```

If you only remember one: **`kubectl describe` and read `Events` from the
bottom up.** Around 90% of failures state their own cause there.

### 21.3 The symptom table

| STATUS / symptom | Most likely cause | First command |
|---|---|---|
| `Pending` | no node fits: resources, taints, selector, unbound PVC | `describe pod` → Events |
| `ContainerCreating` (stuck) | image pull, volume mount, or missing ConfigMap/Secret | `describe pod` → Events |
| `ImagePullBackOff` | bad name/tag, no credentials, not loaded into kind | `describe pod` → Events |
| `CrashLoopBackOff` | app exits: bad config, missing dependency, bad command | `logs --previous` |
| `CreateContainerConfigError` | a referenced ConfigMap/Secret or key does not exist | `describe pod` |
| `OOMKilled` (exit 137) | memory limit too low | `describe pod` → Last State |
| `Running` but `0/1 READY` | readiness probe failing | `describe pod` → probe events |
| `Running`, `1/1`, but 503 | Service has no endpoints, or the client is wrong | `get endpoints` |
| `Terminating` forever | finalizer, or a long grace period | `describe`, check finalizers |
| `Evicted` | node pressure; the pod was BestEffort/Burstable | `describe node` → conditions |
| `Init:0/1` | init container still waiting on a dependency | `logs <pod> -c <init>` |
| `Init:CrashLoopBackOff` | init container exiting non-zero | `logs <pod> -c <init>` |

### 21.4 Exit codes worth recognising

| Code | Means |
|---|---|
| 0 | clean exit. For a server, usually still a bug |
| 1 | generic application error — read the logs |
| 137 | 128 + 9 = SIGKILL. **Almost always OOMKilled** |
| 143 | 128 + 15 = SIGTERM. Normal shutdown |
| 126 | command found but not executable |
| 127 | **command not found** — wrong path or missing binary in the image |

### 21.5 Read the error, do not skim it

Kubernetes errors are unusually informative. Compare:

```
Error from server (Forbidden): pods "x" is forbidden:
User "system:serviceaccount:devboard:intern" cannot delete resource "pods"
in API group "" in the namespace "devboard"
```

That names the **user**, the **verb**, the **resource**, the **API group** and
the **namespace**. It tells you precisely which RBAC rule is missing. Skimming
it and searching the web for "kubernetes forbidden" wastes twenty minutes.

Likewise:

```
0/3 nodes are available: 1 node(s) had untolerated taint
{node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu.
```

Counts per reason. Two different problems, both named.

---

## Part 2 - The drills

### How this works

```bash
# start from a known-good stack
kubectl delete namespace devboard --wait=true
kubectl apply -f ../day-12-wire-the-three-tier-app/solution/
kubectl rollout status deployment/frontend -n devboard --timeout=180s

# break something
bash solution/break.sh 1

# ...diagnose and fix it yourself...

# check your answer
cat solution/scenario-01.md
```

**Rules that make this worth doing:**

1. **Time yourself.** Aim for under 5 minutes per scenario. Interviews are
   timed; on-call is worse.
2. **Write down the diagnosis before you fix it.** "The readiness probe points
   at a path that does not exist" — not "I changed something and it works".
3. **Do not read the answer file until you have fixed it, or spent 10 minutes.**
4. **Fix the root cause**, not the symptom. Deleting the pod is not a fix.

Run `bash solution/break.sh` with no arguments to list all scenarios.

### The eight scenarios

| # | Symptom you will see | Tests |
|---|---|---|
| 1 | Backend pods `Running` but the UI shows no tasks | Services, endpoints, selectors (Day 06) |
| 2 | Frontend pods stuck `ImagePullBackOff` | images, tags, pull policy (Day 08) |
| 3 | Backend `CrashLoopBackOff` after a config change | ConfigMaps, env, `$(VAR)` (Days 09-10) |
| 4 | Postgres `Pending`, nothing schedules | PVC binding, StorageClass (Day 14) |
| 5 | Backend `0/1 Ready`, everything else fine | probes (Day 13) |
| 6 | Backend `OOMKilled` in a loop | resources, limits (Day 16) |
| 7 | Pods `Pending` after a scale-up | scheduling, taints, capacity (Days 16, 18) |
| 8 | Everything healthy, API returns 403 | RBAC (Day 19) |

Scenario 9 (`break.sh 9`) applies **three faults at once** with no hint about
which. Do that one last, and time it.

---

## Part 3 - Debugging tools you should know by now

### Getting inside

```bash
kubectl exec -it <pod> -n devboard -- sh
kubectl exec <pod> -n devboard -c <container> -- env

# no shell in the image? attach one
kubectl debug -it <pod> -n devboard --image=busybox:1.36 --target=<container>

# a throwaway pod with real network tools
kubectl run netshoot --rm -it -n devboard --image=nicolaka/netshoot -- bash
#   inside: dig, curl, nslookup, tcpdump, ss, ip, mtr, nc

# debug a NODE
kubectl debug node/devops-worker -it --image=busybox:1.36
```

### Network checks from inside the cluster

```bash
# DNS
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- nslookup backend
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- nslookup postgres

# HTTP
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- wget -qO- backend:8080/health

# TCP
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- nc -zv postgres 5432

# what does this pod think its DNS config is?
kubectl exec <pod> -n devboard -- cat /etc/resolv.conf
```

### Comparing what you asked for with what is running

```bash
kubectl get deploy backend -n devboard -o yaml > /tmp/live.yaml
diff <(kubectl get deploy backend -n devboard -o yaml) \
     ../day-12-wire-the-three-tier-app/solution/05-backend.yaml

kubectl rollout history deployment/backend -n devboard
kubectl rollout undo    deployment/backend -n devboard      # the fastest fix
```

`kubectl rollout undo` is frequently the correct first response in production:
restore service, then investigate.

### Events, the underused signal

```bash
kubectl get events -n devboard --sort-by=.lastTimestamp | tail -30
kubectl get events -A --field-selector type=Warning
kubectl get events -n devboard --field-selector reason=Unhealthy
kubectl get events -n devboard --field-selector involvedObject.name=backend-abc123
```

Events expire after roughly an hour. `Events: <none>` on an old object means
"nothing recently", not "nothing ever happened".

### Cluster-level health

```bash
kubectl get nodes
kubectl describe node devops-worker | grep -A8 Conditions
kubectl get pods -A --field-selector=status.phase!=Running
kubectl top nodes
kubectl top pods -A --sort-by=memory | head
kubectl get --raw /healthz
kubectl get componentstatuses            # deprecated, still occasionally handy
```

---

## Part 4 - Scenario walkthrough (worked example)

Run `bash solution/break.sh 1`, then follow along. Do the remaining seven
yourself.

**Symptom:** the UI loads, the board is empty, the browser console shows failing
API calls.

**Step 1 — are the pods running?**

```bash
kubectl get pods -n devboard
```

```
NAME                        READY   STATUS    RESTARTS   AGE
backend-6c8b9d7f4-2xk9p     1/1     Running   0          8m
backend-6c8b9d7f4-q7wzl     1/1     Running   0          8m
frontend-7d9f8c4b5-8mn4t    1/1     Running   0          8m
postgres-0                  1/1     Running   0          9m
```

Everything is `Running` and `1/1`. So steps 1 and 2 of the method pass — this is
**not** a pod problem, and no amount of `kubectl logs` on the backend will help.

**Step 2 — can the Service find them?**

```bash
kubectl get endpoints -n devboard
```

```
NAME                ENDPOINTS                          AGE
backend             <none>                             8m
devboard-frontend   10.244.1.15:4173,10.244.2.9:4173   8m
postgres            10.244.1.14:5432                   9m
```

**`backend` has no endpoints** while its pods are healthy. That is definitive: a
Service→Pod problem, which means the **selector** or **readiness**. Readiness is
fine (`1/1`), so it is the selector.

**Step 3 — compare selector with labels.**

```bash
kubectl get svc backend -n devboard -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"devboard-backend"}

kubectl get pods -n devboard --show-labels | grep backend
# app=backend,tier=api
```

`app=devboard-backend` versus `app=backend`. There it is.

**Step 4 — fix the root cause.**

```bash
kubectl patch svc backend -n devboard -p '{"spec":{"selector":{"app":"backend"}}}'
kubectl get endpoints backend -n devboard          # populated
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks
```

**Elapsed: about 90 seconds, three commands, no guessing.** That is the method.
Note that nothing in `kubectl logs` would ever have shown this — the backend
never received a request to log.

---

## Validate

You have finished Day 21 when you can:

1. Solve all eight scenarios in **under 5 minutes each**, without the answers.
2. Solve scenario 9 (three simultaneous faults) in **under 15 minutes**.
3. Recite the four questions of section 21.1 in order.
4. Say what exit code 137 means without looking it up.

Score yourself honestly:

| Scenarios solved unaided | Level |
|---|---|
| 0-3 | revisit the relevant days — the table in Part 2 names them |
| 4-6 | solid junior/mid; drill the ones you missed |
| 7-8 | you can debug a real cluster |
| 8 + scenario 9 under 15 min | interview-ready |

---

## Interview questions

These are asked as scenarios, not definitions. Answer them as a *process*.

<details>
<summary><b>1. A pod is stuck in Pending. Walk me through it.</b></summary>

`kubectl describe pod` and read the FailedScheduling event, which counts nodes
per rejection reason. Then check the candidates in order: insufficient CPU or
memory against requests - remembering the scheduler counts requests, not usage;
an unmatched nodeSelector or required affinity; an untolerated taint; an unbound
PVC, where `kubectl get pvc` shows Pending; required anti-affinity capping
replicas at the node count; a ResourceQuota; or no Ready nodes at all. If it is
scheduled but still not running, it is image pull or volume mounting instead.
</details>

<details>
<summary><b>2. CrashLoopBackOff. What do you do?</b></summary>

`kubectl logs <pod> --previous` first, because the current container has not
started and plain `logs` shows nothing. Then `kubectl describe pod` for the exit
code and Last State. Exit 137 means OOMKilled, so raise the memory limit. Exit
127 means command not found - a bad entrypoint or a missing binary. Exit 1 is an
application error, so read the logs: usually a missing environment variable, an
unreachable dependency, or a bad config file. Also check whether a too-aggressive
liveness probe is killing a container that is merely slow to start.
</details>

<details>
<summary><b>3. A Service returns nothing. How do you debug it?</b></summary>

`kubectl get endpoints <svc>`. If `<none>`, it is Service-to-Pod: the selector
does not match the pod labels, or no pod is Ready - compare
`kubectl get pods --show-labels` against the Service selector. If endpoints are
populated, it is Pod-to-App: wrong targetPort giving connection refused, the app
bound to 127.0.0.1 instead of 0.0.0.0, a NetworkPolicy, or the app itself
erroring. Test from a pod inside the cluster before testing from outside, so you
know which layer you are exercising.
</details>

<details>
<summary><b>4. Everything is Running and Ready but users get 503.</b></summary>

503 typically comes from the ingress controller or load balancer rather than the
application, meaning it has no healthy upstream. Check the Ingress backend
Service name and port, then that Service's endpoints, then whether the readiness
probe is passing on the pods it selects. Contrast with 404, which usually means
the request reached the application and the path was wrong - most often a
missing path rewrite - and 502, which means the upstream refused or errored.
</details>

<details>
<summary><b>5. A node went NotReady. What happens and what do you do?</b></summary>

The node controller taints it `node.kubernetes.io/unreachable:NoExecute`. Pods
get a default five-minute toleration, after which they are evicted and
rescheduled - though pods with ReadWriteOnce volumes may not be able to move.
Investigate the kubelet on that node: is the process running, can it reach the
API server, is the disk full, is there memory pressure. Meanwhile confirm the
workloads that moved actually came back, and check whether a
PodDisruptionBudget or anti-affinity rule is blocking rescheduling.
</details>

<details>
<summary><b>6. Deployment is stuck at 2/3 ready after a rollout.</b></summary>

`kubectl rollout status` reports it is stuck, and `kubectl get pods` shows which
one is unhappy. Usually the new pod cannot become Ready: image pull failure,
failing readiness probe, insufficient capacity for the surge replica, or a
missing ConfigMap or Secret. maxUnavailable is protecting you here - the old
pods are still serving. Fix forward if the cause is obvious, otherwise
`kubectl rollout undo` to restore service and investigate afterwards.
</details>

<details>
<summary><b>7. Data disappeared after a pod restart.</b></summary>

Almost certainly it was written to the container filesystem or an emptyDir
rather than a PersistentVolume - both die with the pod. Check
`kubectl get pod -o yaml` for what is actually mounted where. If a PVC exists,
verify it is Bound, that the mount path matches where the application writes,
and - for a StatefulSet - that the replacement pod reattached the same PVC by
ordinal. Also check that the PV's reclaim policy is not Delete on a claim
someone removed.
</details>

<details>
<summary><b>8. How do you debug a container with no shell?</b></summary>

`kubectl debug -it <pod> --image=busybox --target=<container>` attaches an
ephemeral container sharing the target's process and network namespaces, giving
you tools inside the running pod without rebuilding the image. For node-level
problems, `kubectl debug node/<node> -it --image=busybox` gives a pod with the
host filesystem mounted. Both are far better than the old habit of adding a
shell to production images.
</details>

<details>
<summary><b>9. Your cluster is fine but one microservice is slow. Where do you look?</b></summary>

Start with resources: `kubectl top pods` for usage, and check CPU throttling via
`nr_throttled` in the container's cpu.stat - a CPU limit set too low causes
severe tail latency with no crashes and modest average usage. Then check whether
the Service is load balancing evenly; long-lived HTTP/2 or gRPC connections pin
to one pod, so one replica can be saturated while others idle. Then dependencies:
database latency, connection pool exhaustion, DNS lookups amplified by ndots.
Then whether readiness is flapping, which removes and re-adds pods. Metrics and
tracing beat guessing here - this is where `kubectl top` stops being enough and
Prometheus starts.
</details>

---

## Cheat card — the incident checklist

```bash
# 1. shape of the problem
kubectl get pods -n devboard -o wide
kubectl get events -n devboard --sort-by=.lastTimestamp | tail -20

# 2. the pod itself
kubectl describe pod <pod> -n devboard          # READ THE EVENTS
kubectl logs <pod> -n devboard --previous       # why the last one died
kubectl get pod <pod> -n devboard -o jsonpath='{.status.containerStatuses[0].lastState}'

# 3. the wiring
kubectl get endpoints -n devboard
kubectl get svc <svc> -n devboard -o jsonpath='{.spec.selector}'
kubectl get pods -n devboard --show-labels

# 4. from inside the cluster
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- backend:8080/health

# 5. restore service, then investigate
kubectl rollout undo deployment/<name> -n devboard
```

**The reflex to build:** `describe` before Google. Events before logs. Endpoints
before packet captures.

---

**Next: [The Capstone](../../capstone/)**
