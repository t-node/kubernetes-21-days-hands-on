# Troubleshooting

Symptom → cause → fix, for every failure mode in this course.

---

## The method

Work down the stack. Do not start where the complaint arrived.

```
1. Is the POD running?        kubectl get pods
2. Is the POD ready?          the READY column, not STATUS
3. Can the SERVICE find it?   kubectl get endpoints <svc>
4. Can the CLIENT reach it?   test from inside the cluster, then outside
```

**`kubectl describe` before Google. Events before logs. Endpoints before packet
captures.**

---

## Pod status quick reference

| STATUS | Meaning | First command |
|---|---|---|
| `Pending` | accepted, not scheduled or not started | `describe pod` → Events |
| `ContainerCreating` | normal briefly; stuck = pull or mount problem | `describe pod` |
| `Init:0/1` | init container waiting on a dependency | `logs <pod> -c <init>` |
| `Init:CrashLoopBackOff` | init container exiting non-zero | `logs <pod> -c <init>` |
| `ImagePullBackOff` | cannot fetch the image | `describe pod` → Events |
| `CrashLoopBackOff` | container starts then exits, repeatedly | `logs --previous` |
| `CreateContainerConfigError` | missing ConfigMap/Secret or key | `describe pod` |
| `OOMKilled` | exceeded the memory limit | `describe pod` → Last State |
| `Error` | exited non-zero | `logs --previous` |
| `Completed` | exited 0 — fine for a Job, a bug for a server | `logs` |
| `Terminating` (stuck) | finalizer or long grace period | `describe`, check finalizers |
| `Evicted` | node pressure | `describe node` → Conditions |
| `Running` + `0/1 READY` | **readiness probe failing** | `describe pod` → probe events |

---

## Exit codes

| Code | Means |
|---|---|
| 0 | clean exit. For a server, still a bug |
| 1 | application error — read the logs |
| 126 | command found but not executable |
| 127 | **command not found** — bad entrypoint or missing binary |
| 137 | 128+9 SIGKILL — **almost always OOMKilled** |
| 143 | 128+15 SIGTERM — normal shutdown |

```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

---

## Pending

```bash
kubectl describe pod <pod> | grep -A5 Events
```

| Message | Cause | Fix |
|---|---|---|
| `Insufficient cpu` / `memory` | sum of **requests** exceeds allocatable on every node | lower requests, add nodes, or enable the Cluster Autoscaler |
| `didn't match Pod's node affinity/selector` | no node has the label | fix the selector, or label a node |
| `had untolerated taint {...}` | node repels the pod | add a toleration, or remove the taint |
| `didn't match pod anti-affinity rules` | required anti-affinity, replicas > nodes | use `preferred`, or topology spread |
| `pod has unbound immediate PersistentVolumeClaims` | PVC not Bound | `describe pvc` |
| `waiting for first consumer` (on the PVC) | **normal** for `WaitForFirstConsumer` | nothing; it binds when scheduled |
| `exceeded quota` | ResourceQuota hit | raise the quota or free resources |
| `0/N nodes are available` with idle nodes | **requests, not usage** | right-size requests |

> **The scheduler never looks at actual usage.** Idle nodes can still be "full".

---

## ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <pod> | tail -8
```

| Cause | Check |
|---|---|
| typo in name or tag | `docker images`, the registry |
| tag does not exist | `docker manifest inspect <image>` |
| private registry, no credentials | 401/403 in the event; add `imagePullSecrets` |
| node cannot reach the registry | proxy, firewall, DNS on the node |
| Docker Hub rate limit | `toomanyrequests` in the event |
| **kind: image never loaded** | `docker exec devops-worker crictl images \| grep <image>` |
| **kind: `:latest` forced a remote pull** | set `imagePullPolicy: IfNotPresent` |

That last pair accounts for nearly every occurrence in this course. `:latest`
defaults to `imagePullPolicy: Always`, so the kubelet goes to Docker Hub even
for an image that is demonstrably on the node.

---

## CrashLoopBackOff

```bash
kubectl logs <pod> --previous --tail=50         # the CRASHED container
kubectl describe pod <pod> | grep -A6 "Last State"
```

| Exit code / symptom | Cause |
|---|---|
| 137 | OOMKilled — raise the memory limit |
| 127 | command not found — wrong entrypoint or missing binary |
| 1, with a clear log line | read it; usually config or a dependency |
| 1, no logs at all | it died before logging — **check the memory limit first** |
| restarts climbing, app seems fine | liveness probe too aggressive |
| `FATAL ... no such host` | wrong hostname in config; check the Service name |
| `FATAL ... connection refused` | DNS fine, wrong **port**, or nothing listening |
| `password authentication failed` | wrong credential, or a trailing newline in a Secret |

"BackOff" means Kubernetes is deliberately waiting longer between restarts —
10s, 20s, 40s, capped at 5 minutes. It is not stuck.

---

## Running but not Ready

`RESTARTS: 0` with `READY 0/1` is definitive: **liveness passes, readiness
fails.**

```bash
kubectl describe pod <pod> | grep -A5 -i readiness
```

| Probe error | Cause |
|---|---|
| `HTTP probe failed with statuscode: 404` | the path does not exist — check spelling (`/health` vs `/healthz`) |
| `connection refused` | wrong port, or the app binds `127.0.0.1` instead of `0.0.0.0` |
| `context deadline exceeded` | `timeoutSeconds` too short, or the app is genuinely slow |
| `command ... exited with 1` | the exec probe's own command failed |
| a dependency is down | correct behaviour — the pod left rotation on purpose |

**Consequence:** not-Ready pods are removed from Service endpoints, so a wrong
probe path is a total outage in which every pod reports `Running`.

---

## A Service returns nothing

```bash
kubectl get endpoints <svc> -n <ns>
```

### `ENDPOINTS: <none>`

Service → Pod problem. Only two possibilities:

```bash
kubectl get svc <svc> -o jsonpath='{.spec.selector}'
kubectl get pods --show-labels
kubectl get pods                        # is anything Ready?
```

- selector does not match the pod labels
- no pod is Ready (see the section above)
- wrong namespace

### Endpoints populated but connections fail

| Symptom | Cause |
|---|---|
| `connection refused` | wrong `targetPort`, or the app binds 127.0.0.1 |
| timeout / hang | NetworkPolicy, or a ClusterIP with no live backends |
| `no such host` | wrong Service name, or wrong namespace in the DNS name |
| 5xx from the app | it is not a networking problem; read the logs |

```bash
kubectl run t --rm -i --image=busybox:1.36 --restart=Never -- nslookup <svc>
kubectl run t --rm -i --image=busybox:1.36 --restart=Never -- wget -qO- <svc>:<port>/health
kubectl run t --rm -i --image=busybox:1.36 --restart=Never -- nc -zv <svc> <port>
```

**Always test from inside the cluster first.** It tells you which layer is
broken.

---

## DNS

```bash
kubectl exec <pod> -- cat /etc/resolv.conf
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=30
```

| Form | Resolves from |
|---|---|
| `svc` | the same namespace only |
| `svc.namespace` | anywhere |
| `svc.namespace.svc.cluster.local` | anywhere, fully qualified |
| `pod-0.svc.namespace.svc.cluster.local` | headless Service pods |

`NXDOMAIN` on a short name from another namespace is expected, not a bug — the
search path lists the pod's own namespace first.

`ndots:5` means names with fewer than five dots try the search domains first, so
`api.stripe.com` generates several failed cluster lookups before the real one.
On a busy service that shows up as DNS latency; fix with a trailing dot, a
per-pod `dnsConfig`, or NodeLocal DNSCache.

---

## ConfigMaps and Secrets

| Symptom | Cause |
|---|---|
| `CreateContainerConfigError` | the ConfigMap/Secret or a key does not exist |
| `cannot convert int64 to string` | unquoted number in `data:` — quote it |
| `illegal base64 data` | bad `data:` encoding — use `stringData` |
| changed the ConfigMap, nothing happened | **env vars never update.** `kubectl rollout restart` |
| changed it, the mounted file did not update | `subPath` mounts never update |
| password rejected but looks right | trailing newline from `echo` — use `echo -n` or `stringData` |
| `$(VAR)` appears literally in a value | the referenced variable is undefined — **silent, no error** |
| DSN unparseable | password contains `@` `/` `:` and was not URL-encoded |

```bash
kubectl exec deploy/backend -- env | sort
kubectl get secret s -o jsonpath='{.data.KEY}' | base64 -d | xxd | tail -1
```

---

## Storage

| Symptom | Cause |
|---|---|
| PVC `Pending`, "waiting for first consumer" | **normal** with `WaitForFirstConsumer` |
| PVC `Pending`, "storageclass not found" | the named class does not exist |
| PVC `Pending`, no matching PV | size, access mode or class matches no PV |
| `Multi-Attach error` | a RWO volume already attached on another node |
| two pods writing one volume | RWO means one **node**, not one pod. Use `ReadWriteOncePod` |
| `initdb: directory exists but is not empty` | `lost+found` — set `PGDATA` to a subdirectory |
| data gone after a restart | it was `emptyDir` or the container filesystem |
| PV `Released`, cannot rebind | clear `spec.claimRef` on the PV |
| `delete pvc` destroyed the data | `reclaimPolicy: Delete` — use a Retain class |
| cannot shrink a PVC | not supported. You can only grow |

---

## Resources

| Symptom | Cause | Fix |
|---|---|---|
| `OOMKilled`, exit 137 | memory limit too low | raise it; measure with `kubectl top` |
| slow, no restarts, high `nr_throttled` | CPU limit too low | raise or remove the CPU limit |
| `Evicted` | node pressure; BestEffort/Burstable first | set requests; Guaranteed for critical |
| `Pending` on idle nodes | requests, not usage | right-size requests |
| `must specify limits.cpu` | ResourceQuota with no LimitRange | add a LimitRange with defaults |

```bash
kubectl top pods --containers
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat        # nr_throttled
kubectl get pod <pod> -o jsonpath='{.status.qosClass}'
kubectl describe node <node> | grep -A8 "Allocated resources"
```

---

## HPA

| Symptom | Cause |
|---|---|
| `TARGETS: <unknown>` | **no CPU request**, or metrics-server broken |
| scales up, never down | 5-minute `scaleDown` stabilisation window — wait |
| never scales down at all | scaling on **memory** — most runtimes never release it |
| replica count flapping | a hardcoded `replicas` fighting the HPA |
| scaled, but pods `Pending` | no cluster capacity — the HPA cannot add nodes |
| `minReplicas: 0` rejected | plain HPA cannot scale to zero; use KEDA |
| `FailedGetScale` | the target has no `scale` subresource (e.g. a DaemonSet) |

```bash
kubectl describe hpa backend | grep -A6 Conditions
```

---

## Ingress

| Status | Comes from | Usually means |
|---|---|---|
| `ADDRESS` empty | nothing | no controller claimed it — check `ingressClassName` |
| 404 | **your application** | path rewrite missing or wrong; route not matched |
| 503 | **the controller** | no healthy upstream — Service, endpoints or readiness |
| 502 | the controller | upstream refused or errored the connection |
| 308 | the controller | HTTP to HTTPS redirect (expected with TLS) |
| certificate warning | self-signed, or the wrong Secret |

```bash
kubectl describe ingress devboard | grep -A5 Events
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50
curl -H "Host: devboard.local" http://localhost:8080/api/tasks
```

**404 vs 503 is the most useful distinction here.** 404 means the request
reached your application; 503 means it never did.

---

## RBAC

```
Error from server (Forbidden): deployments.apps is forbidden:
User "system:serviceaccount:devboard:reporting" cannot list resource
"deployments" in API group "apps" in the namespace "devboard"
```

Read all of it: user, verb, resource, **API group**, namespace.

| Symptom | Cause |
|---|---|
| Forbidden on something you granted | wrong `apiGroups` — `deployments` is in `apps`, not `""` |
| can list pods, cannot read logs | `pods/log` is a **separate** subresource |
| can list but not get a named object | `list` and `get` are different verbs |
| a restriction has no effect | RBAC is **additive** — another binding grants it |
| a pod cannot call the API | `automountServiceAccountToken: false`, or the wrong ServiceAccount |

```bash
kubectl auth can-i --list -n devboard --as=system:serviceaccount:devboard:x
kubectl api-resources | grep -E "^deployments"      # which apiGroup?
```

---

## Nodes

| Symptom | Cause |
|---|---|
| `NotReady` | kubelet down, no CNI, disk full, or lost API contact |
| `SchedulingDisabled` | someone ran `kubectl cordon` |
| `MemoryPressure` / `DiskPressure` | the kubelet is evicting; free capacity |
| pods evicted en masse | node pressure, or a `NoExecute` taint |
| pods stuck after a drain | a PDB is blocking, or a volume cannot move |

```bash
kubectl describe node <node> | grep -A10 Conditions
kubectl describe node <node> | grep -A3 Taints
docker exec <node> systemctl status kubelet        # kind
docker exec <node> journalctl -u kubelet -n 50     # kind
```

---

## kind-specific

| Symptom | Cause |
|---|---|
| `localhost:30080` refused | no `extraPortMapping` for that nodePort |
| `EXTERNAL-IP: <pending>` forever | **expected** — no cloud-controller-manager |
| image not found despite `kind load` | `:latest` forced `imagePullPolicy: Always` |
| metrics-server never Ready | needs `--kubelet-insecure-tls` |
| everything gone after a reboot | `docker start devops-control-plane devops-worker devops-worker2` |
| cluster creation hangs | Docker Desktop memory too low — give it 4 GB or more |
| `docker build` 401 on `dhi.io` | Docker Hardened Images — use `app/dockerfiles/` instead |

```bash
docker ps
docker port devops-control-plane
docker exec devops-worker crictl images | grep devboard
bash cluster/recreate-cluster.sh              # nuke and rebuild, about 90 seconds
```

---

## When you are truly stuck

1. **`kubectl describe`** the object and read Events bottom-up.
2. **`kubectl get events -A --sort-by=.lastTimestamp | tail -40`.**
3. **Diff against a known-good manifest** — `kubectl diff -f file.yaml`.
4. **`kubectl rollout undo`** to restore service, then investigate calmly.
5. **Recreate the cluster.** Here that costs 90 seconds and rules out
   accumulated experimental state entirely.

---

## Practise this

[Day 21](days/day-21-break-and-fix-troubleshooting/) has nine deliberately
broken clusters and a script to apply them:

```bash
cd days/day-21-break-and-fix-troubleshooting/solution
bash break.sh          # list
bash break.sh 5        # break it
cat scenario-05.md     # the answer, after you have tried
```
