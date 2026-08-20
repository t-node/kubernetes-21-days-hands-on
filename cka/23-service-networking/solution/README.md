# CKA 23 solution

## Challenge answers

### C1 - Five ways a Service fails

**1. Instant `connection refused`**

**No endpoints.** kube-proxy writes a `REJECT` rule for a Service whose
EndpointSlice is empty, so the failure is immediate rather than a timeout (23.6).

```bash
kubectl get endpoints web
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods --show-labels
kubectl get pods -l app=web        # are they READY, not just Running?
```

Two causes, and they look identical from the client: **the selector matches
nothing**, or **the pods it matches are not `Ready`**. `kubectl describe svc`
shows `Endpoints: <none>` for both; only the pod list distinguishes them.

Fix: correct the selector, or fix whatever the readiness probe is complaining
about.

**2. Hangs, then times out**

The packet went somewhere and nothing answered. The Service is *not* the
problem — endpoints exist and DNAT happened.

```bash
kubectl get endpoints web                    # non-empty
kubectl exec probe -- curl -m5 http://<POD_IP>:8080   # does the POD answer?
kubectl get netpol -A                        # is something dropping it?
kubectl exec POD -- ss -tlnp                 # is the app listening where you think?
```

Most often: **`targetPort` does not match the port the container listens on**, or
a NetworkPolicy ([CKA 18](../../18-network-policies/)) is dropping the traffic.
Testing the pod IP directly separates the two in one command — if the pod
answers and the Service does not, it is the port mapping or policy; if neither
answers, it is the application.

**3. Works from some pods and not others**

**Node-specific.** Every node has its own copy of the rules (23.2), so a
difference between clients on different nodes means a difference between nodes.

```bash
kubectl get pods -o wide                                     # which nodes?
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide  # one per node?
docker exec <bad-node> sh -c 'iptables -t nat -S | grep -c <clusterIP>'
docker exec <good-node> sh -c 'iptables -t nat -S | grep -c <clusterIP>'
```

Usually kube-proxy is dead or wedged on one node. **`kubectl delete pod` on that
node's kube-proxy fixes it**, because it resyncs the entire table on start.

**4. An endpoint for a pod deleted an hour ago**

**kube-proxy or the endpoint controller is not reconciling.** If `kubectl get
endpoints` itself shows the stale address, the *endpoint controller* (in
kube-controller-manager) is the problem, not kube-proxy.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml
kubectl -n kube-system logs -l component=kube-controller-manager --tail=50
kubectl get pods -o wide | grep <stale-ip>       # confirm it really is gone
```

Distinguish carefully: **stale in the API = controller manager; stale in iptables
but correct in the API = kube-proxy.** They are different components and
different fixes.

**5. NodePort refused on one node of three**

Either kube-proxy is broken on that node (as in 3), or the Service uses
**`externalTrafficPolicy: Local`** and that node has no local endpoint — in which
case **the refusal is correct behaviour**, not a fault (23.7).

```bash
kubectl get svc web -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.nodeName}{"\n"}{end}' | sort -u
kubectl get pods -o wide
```

**Check `externalTrafficPolicy` before doing anything else.** Half the "broken
NodePort" reports are `Local` working exactly as designed.

### C2 - Do the arithmetic

**1. Four endpoints:**

| Endpoint | `--probability` | Chance of reaching it |
|---|---|---|
| 1 | `0.2500` | 1/4 |
| 2 | `0.3333` | 3/4 x 1/3 = 1/4 |
| 3 | `0.5000` | 3/4 x 2/3 x 1/2 = 1/4 |
| 4 | (none — fallthrough) | 3/4 x 2/3 x 1/2 = 1/4 |

**2. The proof** is the right-hand column. Each rule is only reached if every
earlier rule failed to match, so its *unconditional* probability is the product
of all the earlier misses and its own hit:

```
P(k) = [ prod over j<k of (1 - 1/(N-j+1)) ] x 1/(N-k+1)
```

Which telescopes to `1/N` for every `k`. Concretely: after rule 1 misses, three
candidates remain and rule 2 takes one third *of that three-quarters* — a
quarter of the whole.

**3. One endpoint becomes unready.**

The kubelet marks the pod not-ready; the endpoint controller removes it from the
EndpointSlice; kube-proxy sees the change and **rewrites the whole `KUBE-SVC`
chain** with three rules at `0.3333`, `0.5000` and the fallthrough.

**Timing:** the readiness probe must fail (`periodSeconds` x `failureThreshold`),
then the controller and kube-proxy each react within their sync interval. In
practice **a few seconds to a few tens of seconds**, dominated by the probe
configuration, not by Kubernetes.

**Existing connections are unaffected** — conntrack keeps them pinned to the
endpoint they already reached (23.5). Only *new* connections avoid it.

**4. Why not `0.25` on all four?**

Because the rules are evaluated **in sequence, not in parallel**. Four rules each
at 0.25 would give the first endpoint 25% of the traffic, the second 25% of the
remaining 75% (18.75%), the third 14%, and the fallthrough the remaining 42%.
**Badly skewed toward the last endpoint.**

The probabilities have to be conditional because iptables offers no "choose one
of N" primitive — only "match this rule or fall through to the next". IPVS, by
contrast, has real scheduling algorithms and needs no such arithmetic, which is
one of the reasons it scales better (23.3).

### C3 - Preserve the client IP

**1. `externalTrafficPolicy: Local`.**

```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
```

**The cost is load balancing.** Kubernetes stops forwarding between nodes, so
traffic arriving at a node is served only by pods on that node. If node A runs
four replicas and node B runs one, and the load balancer splits evenly between
them, **node B's single pod gets half the traffic**. The distribution is now
determined by pod placement, not by the number of pods.

Mitigate it with `topologySpreadConstraints`
([Day 18](../../../days/day-18-scheduling-taints-affinity-daemonsets/)) so replicas
are spread evenly across nodes — which turns an even node split into an even pod
split.

**2. What must change on the load balancer.**

It must **health-check the node port and stop sending to nodes that fail**.
With `Local`, a node without a local endpoint does not answer on that port at
all — so a load balancer doing blind round-robin sends a share of traffic into a
black hole.

Kubernetes publishes a health endpoint for exactly this:

```yaml
spec:
  healthCheckNodePort: 32000     # allocated automatically with Local
```

```bash
curl http://<node>:32000/healthz     # 200 with a local endpoint, 503 without
```

**Point the load balancer's health check at `healthCheckNodePort`, not at the
service port.** Cloud controllers do this automatically; a hardware load balancer
has to be configured by hand, and forgetting it is the usual reason `Local`
"breaks things".

**3. A node with no backing pod** fails the health check, is removed from the
load balancer's pool, and receives nothing. Traffic that does arrive at it —
because the check has not fired yet — is dropped rather than forwarded.

**This is why `Local` is fragile with few replicas.** One pod on a twenty-node
cluster means nineteen nodes serving nothing, and a rolling update briefly means
*zero*.

**4. The alternative: terminate HTTP in front and use `X-Forwarded-For`.**

Put an **Ingress controller** ([Day 20](../../../days/day-20-ingress-and-gateway-api/))
or a cloud L7 load balancer in the path. It sees the real client, adds
`X-Forwarded-For`, and the application reads the header instead of the socket.
The Service behind it can stay on `Cluster` and load balance normally.

**What it costs:** the client IP is now **application-level data, not network
truth**. It can be forged by anyone who can reach the proxy directly, so you must
trust only the header your own proxy added — which means configuring trusted
proxy ranges in the application, and making sure nothing can bypass the proxy to
reach the pods. It also only works for HTTP; a raw TCP or gRPC-over-TCP service
gets nothing from it (the PROXY protocol is the L4 equivalent, if both ends
support it).

**The honest summary:** `Local` gives you the truth at the cost of balancing;
`X-Forwarded-For` gives you balancing at the cost of trusting a header.

### C4 - Sizing a cluster's CIDRs

**1. The arithmetic.**

*Pods:* 60 nodes x 80 pods = 4,800 pods. But allocation is **per node**, so the
node's mask is what matters:

- 80 pods per node needs at least 80 addresses -> **`/25`** (126 usable) is
  tight, **`/24`** (254) is the conventional choice
- 60 nodes x `/24` = 60 x 256 = 15,360 addresses -> a **`/18`** (16,384) fits,
  but leaves no room to grow

**Choose `10.244.0.0/16` with `--node-cidr-mask-size=24`**: 256 possible nodes,
254 pods each. Room for four times the planned node count, at no cost.

*Services:* "a few hundred", so a `/22` (1,022) would do. **Choose
`10.96.0.0/16`** anyway — Service addresses cost nothing, the range is never
routed anywhere, and running out is disproportionately painful.

```
--pod-network-cidr=10.244.0.0/16   --node-cidr-mask-size=24
--service-cidr=10.96.0.0/16
```

**2. Which component gets which flag:**

| Flag | Component | Written by kubeadm into |
|---|---|---|
| `--cluster-cidr` | **kube-controller-manager** | `manifests/kube-controller-manager.yaml` |
| `--node-cidr-mask-size` | **kube-controller-manager** | the same file |
| `--service-cluster-ip-range` | **kube-apiserver** | `manifests/kube-apiserver.yaml` |
| the same service range | **kube-controller-manager** | it also needs it, to avoid allocating conflicts |

At install time you give `kubeadm init` `--pod-network-cidr` and
`--service-cidr` and it distributes them. **And the CNI must be configured with
the same pod CIDR** ([CKA 22](../../22-pod-networking-and-cni/) C5) — that is a
third place, outside kubeadm's control, and the usual source of mismatch.

**3. A pod CIDR that is too small fails when you add the node that does not
fit.**

Say you chose `/20` with a `/24` mask: exactly 16 node allocations. Nodes 1–16
join normally. **Node 17 joins, goes `Ready`, and no pod can ever be scheduled on
it** — the controller manager has no `/24` left to assign, so `spec.podCIDR` is
empty, and the CNI has nothing to allocate from.

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.podCIDR}{"\n"}{end}'
kubectl -n kube-system logs -l component=kube-controller-manager | grep -i cidr
```

**The symptom is a healthy-looking node on which every pod stays
`ContainerCreating`** — and the node count where it starts is a hard cliff, not a
gradual degradation. Nothing warns you at node 16.

**4. Can either be changed later?**

**In practice, no — for both, and for different reasons.**

*Service CIDR:* changing `--service-cluster-ip-range` does not renumber the
Services already allocated from the old range. Every existing ClusterIP is now
outside the configured range, every pod's `KUBERNETES_SERVICE_HOST` is wrong, and
`kubernetes.default` itself is likely broken. Kubernetes has gained a
multi-range mechanism (`ServiceCIDR` objects) that allows *adding* a range, but
shrinking or replacing one is still not a supported operation.

*Pod CIDR:* changing `--cluster-cidr` does not re-issue `spec.podCIDR` on
existing nodes, and every node's routes and CNI configuration still reference the
old range. You would have to drain and rejoin every node, and reconfigure the
CNI — at which point you have rebuilt the cluster with extra steps.

**The real answer to both is "build a new cluster and migrate."** Which is
precisely why these two numbers deserve five minutes of arithmetic on day one,
and why the advice is always to pick generously.

### C5 - Explain the OUTPUT hook

**Neither is redundant. They catch traffic at two different moments.**

The kernel's NAT table runs `PREROUTING` on packets that **arrive on an
interface**, and `OUTPUT` on packets that are **generated locally**. A packet is
only ever one or the other, so a Service rule reachable from just one of them
would be invisible to half the traffic.

**`PREROUTING` handles traffic that arrives from elsewhere:**

> A pod on node B calls `web.default.svc` (`10.96.14.7`). The packet leaves node
> B, crosses the network, and **arrives on node A's `eth0`**. It hits
> `PREROUTING`, matches `KUBE-SERVICES`, and is DNAT'd to a pod address.

Also: a NodePort request from your laptop, a health check from a load balancer,
anything crossing the wire.

**`OUTPUT` handles traffic generated on the node itself:**

> The **kubelet** on node A calls a webhook Service ([CKA 07](../../07-admission-controllers/)).
> The packet is created by a local process; it never arrives on an interface, so
> **`PREROUTING` never sees it**. `OUTPUT` catches it on the way to the routing
> decision.

Also: a pod on node A calling a Service — the packet originates in a namespace on
that host and is, from the kernel's point of view, locally generated.

**What breaks if `OUTPUT` is removed:**

**Every ClusterIP becomes unreachable from the node that is trying to use it**,
while remaining perfectly reachable from every other node. Concretely:

- pods can reach Services on *other* nodes but not ones they are calling from
  their own node — except that they cannot tell the difference, so it presents as
  **intermittent failures at roughly 1/N**
- **DNS breaks first and hardest**, because `10.96.0.10` is a ClusterIP and every
  pod resolves through it. Name resolution fails for a fraction of lookups
- the kubelet cannot reach admission webhooks, metrics-server, or anything else
  it calls through a Service
- `curl` from a shell on the node to any ClusterIP times out

It is the kind of failure that produces a week of confused debugging, because
everything is *mostly* fine.

**The specific case asked about — a pod on node A calling a Service whose only
endpoint is also on node A:**

**`OUTPUT`.** The packet is generated by a process in a namespace on node A. It
does not traverse an external interface on the way in, so `PREROUTING` is not
consulted; `OUTPUT` matches, `KUBE-SERVICES` DNATs the destination to the local
pod's address, and the packet is delivered over the bridge without leaving the
machine.

**The whole round trip stays inside one host** — which is why intra-node Service
traffic is fast, and why a node with a broken `OUTPUT` hook fails in exactly the
cases you would expect to be the most reliable.

---

## Files

| File | Purpose |
|---|---|
| `01-workload.yaml` | three replicas serving their own names, with a readiness probe |
| `02-service-wrong-selector.yaml` | a Service that matches nothing -- the REJECT rule |
| `03-nodeport.yaml` | two NodePorts differing only in `externalTrafficPolicy` |
| `04-session-affinity.yaml` | `sessionAffinity: ClientIP` and the `recent` module |
| `05-headless.yaml` | `clusterIP: None` -- zero iptables rules |
| `trace-service.sh` | walks KUBE-SERVICES -> KUBE-SVC -> KUBE-SEP and checks the probability arithmetic |
| `run-in-node.sh` | copy a script into a kind node and run it there |
| `verify.sh` | checks every claim in Part 4 |

---

## On `trace-service.sh`

It exists because **`kubectl` cannot show you a Service's implementation**. The
object in etcd tells you what was asked for; the iptables chains tell you what is
actually happening, and when the two disagree the second one is what users
experience.

The script's most useful section is the arithmetic: it computes the probabilities
that *should* be there for N endpoints and prints them next to the ones that
*are*. A mismatch means kube-proxy has not resynced — which is Step 8's failure
mode, and one of the few Service problems that is invisible from the API.

Run it against `kube-dns` for a Service you did not create:

```bash
DNS=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}')
bash solution/run-in-node.sh trace-service.sh "$DNS" 53
```

**Same three-layer structure.** There is nothing special about the Services
Kubernetes ships with — which is the point worth ending on.
