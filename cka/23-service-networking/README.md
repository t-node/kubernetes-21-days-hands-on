# CKA 23 — Service Networking

**Time:** 90-110 minutes
**Prerequisites:** [Day 06](../../days/day-06-services-clusterip-and-dns/), [Day 07](../../days/day-07-services-nodeport-loadbalancer/), [CKA 21](../21-linux-networking-foundations/), [CKA 22](../22-pod-networking-and-cni/)
**Source lectures:** 222, 224

[Day 06](../../days/day-06-services-clusterip-and-dns/) taught you to create a
Service and use it. This assignment answers the question that follows: **what is
a Service, actually?** The answer is unsettling and worth internalising — it is
not a process, not an interface, and not a thing that exists on any machine.

---

## Part 1 - Concepts

### 23.1 A Service does not exist

A pod has a network namespace, an interface and an address you can find with
`ip addr`. **A Service has none of those.**

```bash
kubectl get svc kubernetes            # ClusterIP 10.96.0.1
ip addr | grep 10.96.0.1              # nothing, on any node
ip route get 10.96.0.1                # routed to the default gateway -- nowhere real
```

**Nothing is listening on a ClusterIP.** No process binds it, no interface owns
it, no host answers ARP for it, and there is no route to it. That is why most
ClusterIPs do not respond to `ping` — and why "the Service IP does not ping" is
not a fault report.

What a Service *is*:

1. **an object in etcd** — the desired state
2. **a set of iptables rules on every node** — the implementation

The rule says: *any packet whose destination is `10.96.14.7:80`, rewrite the
destination to one of these pod addresses.* The packet is then routed normally,
by the mechanism from [CKA 21](../21-linux-networking-foundations/). The
ClusterIP never appears on the wire beyond the first hop.

### 23.2 kube-proxy writes the rules

```
   API server
       |  watch Services and EndpointSlices
       v
   kube-proxy  (a DaemonSet -- one pod per node)
       |
       v
   iptables / IPVS rules, on THIS node
```

**kube-proxy is not a proxy.** Despite the name, in its default mode no traffic
passes through it. It is a **controller** in the sense of
[CKA 19](../19-crds-controllers-operators/): it watches two resources and writes
kernel state to match.

Two consequences worth stating plainly:

- **Every node has rules for every Service**, whether or not any backing pod runs
  there. That is what makes a ClusterIP reachable from anywhere.
- **kube-proxy dying does not break existing Services.** The rules it already
  wrote stay in the kernel. What stops is *updating* them — new Services get no
  rules, and a pod that dies is never removed from the rotation. You will
  reproduce this in Part 2.

### 23.3 Three proxy modes

| Mode | How | Status |
|---|---|---|
| `userspace` | kube-proxy really did proxy every connection | **removed** -- slow |
| **`iptables`** | DNAT rules, evaluated in the kernel | **the default** |
| `ipvs` | the kernel's L4 load balancer, hash tables | for very large clusters |
| `nftables` | the modern replacement for iptables | newer, opt-in |

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode
```

**`iptables` mode is a linear list.** Rules are evaluated in order, so a cluster
with 5,000 Services makes the kernel walk thousands of rules per new connection,
and makes each kube-proxy resync rewrite the whole table. **`ipvs` mode uses hash
lookups** — O(1) instead of O(n) — and supports real scheduling algorithms
(`rr`, `lc`, `sh`) rather than only random.

The threshold is usually put at around a thousand Services. Below it, `iptables`
is simpler and universally understood; above it, `ipvs` is the difference between
a working cluster and one where adding a Service takes seconds.

### 23.4 Two CIDRs that must not overlap

| Range | Set on | Flag |
|---|---|---|
| **Service CIDR** | kube-apiserver | `--service-cluster-ip-range` |
| **Pod CIDR** | kube-controller-manager | `--cluster-cidr` |

```bash
grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml
grep cluster-cidr /etc/kubernetes/manifests/kube-controller-manager.yaml
```

```
--service-cluster-ip-range=10.96.0.0/16
--cluster-cidr=10.244.0.0/16
```

**If these overlap, an address can be both a pod and a Service**, and traffic to
it goes wherever the kernel matches first. The failure is intermittent and nearly
undiagnosable, which is why both flags are set once at `kubeadm init` and never
changed afterwards.

Note the sizing: a `/16` of Services is 65,534 Services **cluster-wide**; a `/16`
of pods is carved into a `/24` **per node**
([CKA 22](../22-pod-networking-and-cni/)). The first is a cluster total, the
second a per-node allocation — a distinction that catches people sizing a cluster
for the first time.

### 23.5 The chain walk

Every Service becomes the same three-layer structure:

```
  KUBE-SERVICES                       (called from PREROUTING and OUTPUT)
     -d 10.96.14.7/32 --dport 80  ->  KUBE-SVC-XXXXXXXX

  KUBE-SVC-XXXXXXXX                   (one chain per Service port)
     -m statistic --mode random --probability 0.3333  ->  KUBE-SEP-AAA
     -m statistic --mode random --probability 0.5000  ->  KUBE-SEP-BBB
                                                      ->  KUBE-SEP-CCC

  KUBE-SEP-AAA                        (one chain per endpoint)
     -j DNAT --to-destination 10.244.1.5:8080
```

**The probabilities are not equal, and that is correct.** With three endpoints
the first fires 1/3 of the time; if it does not, the second sees the remaining
2/3 and fires with probability 1/2 of that — another 1/3; the last is the
fallthrough. **1/N, then 1/(N-1), then 1/(N-2)... down to 1.** Do the arithmetic
once and the odd-looking numbers become obvious.

**Load balancing is per connection, not per packet**, because conntrack records
the translation:

```bash
conntrack -L | grep 10.96.14.7
```

Every subsequent packet of that TCP flow follows the same path automatically.

**`KUBE-SERVICES` is called from both `PREROUTING` and `OUTPUT`** — the first for
traffic arriving from elsewhere, the second for traffic originating on the node
itself, including from a pod on that node. Without the `OUTPUT` hook a pod could
not reach a Service on its own node.

### 23.6 Endpoints come from readiness

kube-proxy does not look at pods. It watches **EndpointSlices**, which the
endpoint controller fills from a Service's selector:

```bash
kubectl get endpoints web
kubectl get endpointslices -l kubernetes.io/service-name=web
```

| Object | |
|---|---|
| `Endpoints` | the original -- one object per Service, does not scale past ~1000 endpoints |
| `EndpointSlice` | the modern form -- up to 100 endpoints per slice, several slices per Service |

**Only `Ready` pods become endpoints.** A pod failing its readiness probe
([Day 13](../../days/day-13-health-probes/)) is removed from the slice, kube-proxy
rewrites the chain, and traffic stops reaching it — **while the pod keeps
running**. That is the entire mechanism behind readiness probes, and it is worth
watching happen.

**A Service with no endpoints still has a ClusterIP and still has rules** — rules
that reject. `curl` gets `connection refused` immediately rather than hanging,
which is a useful signal: **instant refusal means the Service exists and has no
backends.**

### 23.7 NodePort and the source IP

A NodePort adds one more entry point:

```
  KUBE-NODEPORTS   -p tcp --dport 31234  ->  KUBE-EXT-XXXX  ->  KUBE-SVC-XXXX
```

**The port is opened on every node**, whether or not a backing pod runs there.
Traffic arriving at a node with no local endpoint is forwarded to a node that has
one — **and SNAT'd on the way**, so the backend sees the node's address instead
of the client's.

```yaml
spec:
  externalTrafficPolicy: Cluster     # default
```

| Policy | Behaviour |
|---|---|
| **`Cluster`** | any node accepts; traffic may cross nodes; **client IP is lost** |
| **`Local`** | only nodes with a local endpoint accept; no second hop; **client IP preserved** |

**`Local` trades load balancing for source IP.** A node with no pod fails its
health check and the external load balancer stops sending to it — which is why
`Local` is right behind a cloud load balancer and wrong when you are hitting node
IPs directly by hand.

### 23.8 Session affinity

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

kube-proxy implements it with iptables' `recent` module: the first connection
from a client address picks an endpoint and records it, and later connections
from the same address match the record and reuse it.

**It is per client IP, not per user.** Everything behind a NAT gateway is one
client, and any SNAT in front of the Service (23.7) collapses every client into
one. **`sessionAffinity` is not a substitute for real sessions**, and treating it
as one is how a "sticky" service ends up sending 90% of its traffic to one pod.

### 23.9 Headless Services have no rules at all

```yaml
spec:
  clusterIP: None
```

**No ClusterIP, so nothing for kube-proxy to write.** Instead, DNS returns the
pod addresses directly — one A record per ready endpoint
([Day 15](../../days/day-15-statefulsets-and-headless-services/)).

```bash
kubectl exec pod -- nslookup my-headless-svc
# returns N addresses, not one
```

**No load balancing, no DNAT, no single IP.** The client picks. That is what a
StatefulSet needs, what a client-side load balancer needs, and what makes
"connect to a specific replica" possible.

Grep for a headless Service in iptables and you find nothing — which is a good
check that you have understood what a ClusterIP actually is.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka23
kubectl config set-context --current --namespace=cka23
kubectl apply -f solution/01-workload.yaml
kubectl rollout status deployment/web --timeout=120s
kubectl get pods -o wide
```

### Step 1: The address that is not there

```bash
SVC=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
echo "$SVC"

docker exec devops-worker sh -c "ip addr | grep '$SVC'"          # nothing
docker exec devops-control-plane sh -c "ip addr | grep '$SVC'"   # nothing
docker exec devops-worker ip route get "$SVC"
```

**No interface on any node owns it** (23.1). Yet:

```bash
kubectl run probe --image=curlimages/curl:8.10.1 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/probe --timeout=60s
kubectl exec probe -- curl -s "http://$SVC"
```

It answers. **An address that exists nowhere is serving traffic** — because
something rewrites the destination before the packet is routed.

### Step 2: Walk the chains

```bash
bash solution/run-in-node.sh trace-service.sh "$SVC" 80
```

Five sections, and the arithmetic in section 2 is the point:

```
   3 endpoint chain(s). Expected probabilities for 3 endpoints:
     endpoint 1: 1/3 = 0.3333
     endpoint 2: 1/2 = 0.5000
     endpoint 3: 1/1 = 1.0000
```

Compare against the real rules the script printed above it. **They match, and now
they make sense** (23.5).

Watch the arithmetic change as you scale:

```bash
kubectl scale deployment/web --replicas=5
kubectl rollout status deployment/web --timeout=90s
sleep 5
bash solution/run-in-node.sh trace-service.sh "$SVC" 80 | sed -n '/KUBE-SVC/,/endpoint chains/p'
```

Five endpoints, probabilities `0.2000`, `0.2500`, `0.3333`, `0.5000` and the
fallthrough. **kube-proxy rewrote every rule when the EndpointSlice changed.**

```bash
kubectl scale deployment/web --replicas=3
```

Confirm the distribution really is even:

```bash
kubectl exec probe -- sh -c "for i in \$(seq 1 30); do curl -s http://$SVC; echo; done" | sort | uniq -c
```

```
     11 web-6f4b8c9d-abcde
      9 web-6f4b8c9d-fghij
     10 web-6f4b8c9d-klmno
```

### Step 3: Endpoints come from readiness

```bash
kubectl get endpoints web
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{.items[0].endpoints[*].conditions.ready}{"\n"}'
```

Now break one pod's readiness **without stopping it**:

```bash
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- mv /usr/share/nginx/html/index.html /tmp/index.html
sleep 10

kubectl get pods -l app=web
kubectl get endpoints web
```

```
NAME                   READY   STATUS    RESTARTS   AGE
web-6f4b8c9d-abcde     0/1     Running   0          8m      <- still Running
```

**`0/1` and still `Running`.** The container did not stop and was not restarted;
it simply stopped passing its readiness probe. And:

```bash
bash solution/run-in-node.sh trace-service.sh "$SVC" 80 | grep -A6 "endpoint chain"
```

**Two endpoints now, not three.** kube-proxy rewrote the chain within seconds of
the EndpointSlice changing (23.6). Traffic confirms it:

```bash
kubectl exec probe -- sh -c "for i in \$(seq 1 20); do curl -s http://$SVC; echo; done" | sort | uniq -c
```

The unready pod's name does not appear. **That is the whole purpose of a
readiness probe**, and here it is as an iptables rule.

```bash
kubectl exec "$POD" -- mv /tmp/index.html /usr/share/nginx/html/index.html
sleep 10
kubectl get endpoints web
```

### Step 4: A Service with no backends

```bash
kubectl apply -f solution/02-service-wrong-selector.yaml
kubectl get svc web-broken
kubectl get endpoints web-broken
```

```
NAME         ENDPOINTS   AGE
web-broken   <none>      5s
```

**It has a ClusterIP and no endpoints.** What happens on the wire:

```bash
BROKEN=$(kubectl get svc web-broken -o jsonpath='{.spec.clusterIP}')
kubectl exec probe -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" "http://$BROKEN"
```

```
000
```

...and it returned **instantly**, not after five seconds. Find out why:

```bash
bash solution/run-in-node.sh trace-service.sh "$BROKEN" 80
```

```
-A KUBE-SERVICES -d 10.96.x.x/32 -p tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

**A REJECT rule, not a missing rule.** kube-proxy deliberately writes one for a
Service with no endpoints, so clients fail fast instead of hanging.

**That instant `connection refused` is a diagnostic**: the Service object exists,
kube-proxy is working, and the selector matches nothing. Compare with a *timeout*,
which means the packet went somewhere and nothing answered.

```bash
kubectl get svc web-broken -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods --show-labels -l app=web
```

The selector says `app: web-typo`; the pods say `app: web`. **A Service with no
endpoints is almost always a selector that does not match, or pods that are not
Ready.**

```bash
kubectl delete -f solution/02-service-wrong-selector.yaml
```

### Step 5: NodePort, and what happens to the client's address

```bash
kubectl apply -f solution/03-nodeport.yaml
kubectl get svc -o wide
```

The repo's kind cluster maps 30080 and 30081 through to your workstation
([SETUP.md](../../SETUP.md)), so both are reachable directly:

```bash
for i in $(seq 1 12); do curl -s http://localhost:30080; echo; done | sort | uniq -c
```

Traffic reaches all three pods, from whichever node the request landed on. Find
the rule that made it happen:

```bash
docker exec devops-worker sh -c 'iptables -t nat -S KUBE-NODEPORTS | grep 30080'
```

Now the source-address difference. Ask the backend what it saw:

```bash
curl -s http://localhost:30080 >/dev/null
curl -s http://localhost:30081 >/dev/null
kubectl logs -l app=web --tail=20 --prefix | grep -E '30080|GET' | tail -6
```

Look at the client addresses in nginx's log. For **`web-np-cluster`** you will
often see a **node** address (`172.18.0.x`) — the packet was forwarded to another
node and SNAT'd on the way (23.7). For **`web-np-local`** the address is the
original client's.

Prove the other half of `Local` — that only nodes with a pod answer:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-np-local \
  -o jsonpath='{range .items[*].endpoints[*]}{.nodeName}{"\n"}{end}' | sort -u

docker exec devops-worker  sh -c 'iptables -t nat -S | grep -c 30081'
docker exec devops-worker2 sh -c 'iptables -t nat -S | grep -c 30081'
```

**A node with no local endpoint has no path for that port** — it fails the
external health check rather than forwarding. That is the trade: source IP
preserved, load balancing delegated to whatever is in front.

```bash
kubectl delete -f solution/03-nodeport.yaml
```

### Step 6: Session affinity

```bash
kubectl apply -f solution/04-session-affinity.yaml
STICKY=$(kubectl get svc web-sticky -o jsonpath='{.spec.clusterIP}')
kubectl exec probe -- sh -c "for i in \$(seq 1 15); do curl -s http://$STICKY; echo; done" | sort | uniq -c
```

```
     15 web-6f4b8c9d-abcde
```

**Every request to one pod.** Compare against `web`, which spread them evenly.
The mechanism:

```bash
docker exec devops-worker sh -c "iptables -t nat -S | grep -A2 -B2 'recent' | head -12"
```

`-m recent --rcheck --seconds 600` — the `recent` module remembering which client
went where (23.8).

**Note what "client" means here.** Everything comes from one pod, so there is one
client IP and one sticky endpoint. Behind a NAT gateway, or behind a Service with
`externalTrafficPolicy: Cluster`, thousands of users collapse into one client
address and one pod gets all the traffic.

```bash
kubectl delete -f solution/04-session-affinity.yaml
```

### Step 7: Headless — no rules at all

```bash
kubectl apply -f solution/05-headless.yaml
kubectl get svc web-headless
```

```
NAME           TYPE        CLUSTER-IP   PORT(S)   AGE
web-headless   ClusterIP   None         80/TCP    3s
```

```bash
docker exec devops-worker sh -c 'iptables -t nat -S | grep -c web-headless'
```

```
0
```

**Zero rules.** There is no virtual IP to translate, so kube-proxy has nothing to
do (23.9). DNS does the work instead:

```bash
kubectl exec probe -- nslookup web-headless.cka23.svc.cluster.local 2>&1 | tail -12
```

**Three A records**, one per ready endpoint, versus one record for the normal
Service:

```bash
kubectl exec probe -- nslookup web.cka23.svc.cluster.local 2>&1 | tail -5
```

The client now chooses. **This is the difference between server-side load
balancing (a ClusterIP) and client-side (headless)**, and it is why StatefulSets
use it.

```bash
kubectl delete -f solution/05-headless.yaml
```

### Step 8: Take kube-proxy away

```bash
kubectl -n kube-system get daemonset kube-proxy
kubectl -n kube-system patch daemonset kube-proxy \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kube-proxy":"disabled"}}}}}'
kubectl -n kube-system get pods -l k8s-app=kube-proxy -w   # they terminate; Ctrl-C
```

Now test the Service you already have:

```bash
kubectl exec probe -- curl -s -m 5 "http://$SVC"
```

**It still works.** The rules kube-proxy wrote are in the kernel and nothing
removed them (23.2). Now create something new:

```bash
kubectl expose deployment web --name=web-after --port=80
NEW=$(kubectl get svc web-after -o jsonpath='{.spec.clusterIP}')
sleep 10
kubectl exec probe -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" "http://$NEW"
docker exec devops-worker sh -c "iptables -t nat -S | grep -c '$NEW'"
```

```
000
0
```

**No rules, no service.** And the more dangerous half — scale down and watch a
dead pod stay in the rotation:

```bash
kubectl scale deployment/web --replicas=1
sleep 15
kubectl get endpoints web
docker exec devops-worker sh -c "iptables -t nat -S | grep -c KUBE-SEP"
```

**The EndpointSlice updated; the iptables rules did not.** Two thirds of requests
now go to pods that no longer exist.

Restore it:

```bash
kubectl -n kube-system patch daemonset kube-proxy --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/kube-proxy"}]'
kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=120s
kubectl scale deployment/web --replicas=3
sleep 10
kubectl delete svc web-after
kubectl exec probe -- curl -s "http://$SVC"
```

**kube-proxy resyncs the whole table on startup**, so everything corrects itself
within seconds of it returning. That is why "restart kube-proxy" fixes so many
Service problems — and why a cluster can look healthy for hours with kube-proxy
dead on one node.

### Cleanup

```bash
kubectl delete namespace cka23 --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Five ways a Service fails

For each symptom give the most likely cause, the confirming command, and the fix:

1. `curl` to the ClusterIP returns `connection refused` **instantly**
2. `curl` **hangs** and then times out
3. The Service works from some pods and not others
4. `kubectl get endpoints` lists an address that belongs to a pod that was
   deleted an hour ago
5. The Service works from inside the cluster but the NodePort is refused on one
   of three nodes

### C2 - Do the arithmetic

A Service has **four** endpoints.

1. Write the four `--probability` values kube-proxy will use.
2. Prove they produce an even split.
3. One endpoint becomes unready. What changes, and how long does it take?
4. Why does kube-proxy not simply use `--probability 0.25` on all four?

### C3 - Preserve the client IP

An application must log real client addresses. It is exposed as a NodePort behind
a hardware load balancer that does no header insertion.

1. Which setting, and what does it cost?
2. What must change on the load balancer for it to keep working?
3. What happens to a node that has no backing pod?
4. Give an alternative that preserves the client IP **without** that trade-off,
   and say what it costs instead.

### C4 - Sizing a cluster's CIDRs

You are designing a cluster: up to 60 nodes, 80 pods per node, and "a few
hundred" Services.

1. Choose a pod CIDR and a Service CIDR, and show the arithmetic.
2. Which component gets which flag?
3. What happens if you pick a pod CIDR that is too small — at what point does it
   fail, and what does the failure look like?
4. Can either be changed later? Say what is actually involved.

### C5 - Explain the OUTPUT hook

A colleague notices `KUBE-SERVICES` is called from both `PREROUTING` and
`OUTPUT` and asks whether one is redundant.

Explain what each handles with a concrete example, describe exactly what would
break if `OUTPUT` were removed, and say which is involved when a pod on node A
calls a Service whose only endpoint is on node A.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the ClusterIP exists on no interface; a `KUBE-SVC` chain exists with one
`KUBE-SEP` per ready endpoint and the expected probabilities; a Service with no
endpoints has a REJECT rule; unready pods leave the EndpointSlice while staying
Running; a headless Service has zero iptables rules; and the Service and pod
CIDRs do not overlap.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the three objects that make a Service work
kubectl get svc web -o wide
kubectl get endpoints web
kubectl get endpointslices -l kubernetes.io/service-name=web

# the two CIDRs
grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml
grep cluster-cidr /etc/kubernetes/manifests/kube-controller-manager.yaml

# what proxy mode?
kubectl -n kube-system get cm kube-proxy -o yaml | grep mode
kubectl -n kube-system logs -l k8s-app=kube-proxy | grep -i "using.*proxier"

# the rules for one Service
iptables -t nat -S | grep <clusterIP>
iptables -t nat -S KUBE-SERVICES | grep <clusterIP>
iptables -t nat -S KUBE-SVC-XXXXXXXX
iptables -t nat -S | grep KUBE-NODEPORTS

# IPVS mode instead
ipvsadm -ln

# what is actually being translated right now
conntrack -L | grep <clusterIP>

# is it a selector problem?
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods --show-labels
kubectl describe svc web | grep -A2 Endpoints
```

**Traps**

- **A ClusterIP exists on no interface.** It cannot be pinged, cannot be found in
  `ip addr`, and has no route. That is normal.
- **kube-proxy is not in the data path** in iptables mode. Killing it leaves
  existing Services working and stops updates.
- **The endpoint probabilities are 1/N, 1/(N-1), ...**, not 1/N each.
- **Only `Ready` pods are endpoints.** A `Running` pod at `0/1` receives no
  traffic.
- **Instant `connection refused` = no endpoints** (a REJECT rule). A **timeout**
  is a different problem entirely.
- **`kubectl get endpoints` is the first command** for any Service problem, before
  looking at DNS, policy or the application.
- **NodePort opens on every node**, and `externalTrafficPolicy: Cluster` **loses
  the client IP** to SNAT.
- **`externalTrafficPolicy: Local`** keeps the client IP and makes nodes without a
  pod stop answering.
- **`sessionAffinity: ClientIP` is per address**, so any NAT in front collapses
  all clients into one.
- **A headless Service has no ClusterIP and no iptables rules at all.**
- **Service CIDR and pod CIDR must not overlap**, and neither is changeable in
  practice.
- **`Endpoints` is legacy; `EndpointSlice` is what kube-proxy watches.** Both
  exist for compatibility.

---

**Previous:** [CKA 22 — Pod Networking and CNI](../22-pod-networking-and-cni/)
**Next: CKA 24 — DNS and CoreDNS** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
