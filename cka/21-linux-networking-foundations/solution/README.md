# CKA 21 solution

## Challenge answers

### C1 - Read a routing table

```
default via 10.0.0.1 dev eth0
10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.15
10.244.1.0/24 dev cni0 proto kernel scope link src 10.244.1.1
10.244.0.0/24 via 10.0.0.11 dev eth0
10.244.2.0/24 via 10.0.0.12 dev eth0
```

**1. This node is `10.0.0.15`; its pod CIDR is `10.244.1.0/24`.**

Both come from the `src` field on the two `scope link` lines — those are
directly attached networks, and `src` is the address this host uses on each. The
node is `10.0.0.15` on `eth0` and `10.244.1.1` on `cni0`, which is the **bridge
gateway address** every pod on this node uses as its default route.

**2. Two other nodes: `10.0.0.11` and `10.0.0.12`.** Each `via` line is one
remote node's pod CIDR reachable through that node's own IP. **Counting `via`
lines to `10.244.x` is how you count nodes from a routing table.**

**3. A packet to `10.244.2.7`:**

1. leaves the pod on its `eth0`, arrives on the node's `cni0` bridge
2. the kernel matches the most specific route: `10.244.2.0/24 via 10.0.0.12`
3. it is forwarded out `eth0` toward `10.0.0.12` — which requires
   `ip_forward=1` (21.3)
4. node `10.0.0.12` receives it, matches its own `10.244.2.0/24 dev cni0`, and
   delivers it to the pod

**No encapsulation and no NAT.** The pod's source address stays `10.244.1.x` all
the way, which is exactly what "pods can reach pods without NAT" means.

**4. A packet to `8.8.8.8`:** no specific route matches, so `default via
10.0.0.1` is used and it goes out `eth0`.

**For a reply to arrive, a MASQUERADE rule must rewrite the source** (21.6). The
internet has no route back to `10.244.1.x`; the packet must leave with the
node's `10.0.0.15` as its source. That rule lives in `POSTROUTING` and is
installed by the CNI plugin or by kube-proxy. **Missing it is a classic
symptom: pods reach each other and every other node, and nothing outside.**

**5. Delete `10.244.2.0/24 via 10.0.0.12`.**

The symptom is beautifully confusing: everything works except traffic to the
pods on one node. Since a Service load-balances across pods on several nodes,
**roughly a third of requests to a three-replica Service time out and the rest
succeed** — intermittent failures with no pattern the application can see, which
is why "check the routing table on every node" belongs early in a networking
runbook.

### C2 - Two failures that look the same

**`Network is unreachable`** — the kernel found **no route** to `10.96.0.10` and
never sent a packet. In a pod this almost always means the default route is
missing, so the CNI did not finish wiring the namespace.

```bash
kubectl exec POD -- ip route
# expect: default via 10.244.1.1
```

**A timeout** — a route existed, the packet left, and nothing came back. Now the
possibilities are downstream: kube-proxy has no rules for that ClusterIP,
CoreDNS is down, a NetworkPolicy is dropping it ([CKA 18](../../18-network-policies/)),
or a return path is broken.

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl get endpoints -n kube-system kube-dns
kubectl get netpol -A
```

**The one that is not a Kubernetes problem is `Network is unreachable`** — at
that instant it is a plain Linux routing failure inside the namespace. Kubernetes
caused it, but nothing about Services, DNS or policy is involved and looking
there wastes the first ten minutes.

**The one command that separates them:**

```bash
ip route get 10.96.0.10
```

It answers instantly with either the route the kernel would use, or
`RTNETLINK answers: Network is unreachable`. **No packet is sent**, so there is
nothing to wait for.

### C3 - Match the veth

**From the interface to the pod.** The `@if8` suffix names the peer's index in
the *other* namespace:

```bash
# 1. on the node, confirm the peer index
ip -o link show veth7a3f21          # veth7a3f21@if8 -- peer is index 8

# 2. walk every pod namespace looking for interface index 8 whose peer is this one
for pid in $(crictl inspect $(crictl ps -q) 2>/dev/null | grep -m1 '"pid"' | tr -dc '0-9'); do
  nsenter -t "$pid" -n ip -o link show 2>/dev/null | grep '^8:'
done
```

The reliable version, which is what to use in practice:

```bash
# ask the interface for its peer's index directly
ip -d link show veth7a3f21 | grep -o 'link-netnsid [0-9]*'

# then, for each pod on the node, compare its eth0 peer index against this
# interface's own index
IDX=$(cat /sys/class/net/veth7a3f21/ifindex)
for c in $(crictl ps -q); do
  p=$(crictl inspect "$c" | grep -m1 '"pid"' | tr -dc '0-9')
  peer=$(nsenter -t "$p" -n ip -o link show eth0 2>/dev/null | sed -n 's/.*eth0@if\([0-9]*\).*/\1/p')
  [ "$peer" = "$IDX" ] && echo "MATCH: $(crictl inspect "$c" | grep -m1 '"name"')"
done
```

**From a known pod to its interface** — far easier, and the direction you
usually want:

```bash
kubectl exec POD -- cat /sys/class/net/eth0/iflink        # e.g. 8
# then on the node:
grep -l 8 /sys/class/net/*/ifindex
```

Or in one step:

```bash
PID=$(docker exec node crictl inspect $(docker exec node crictl ps --name POD -q) | grep -m1 '"pid"' | tr -dc '0-9')
docker exec node nsenter -t "$PID" -n ip -o link show eth0
```

**The general principle: `ifindex` and `iflink` are the two halves of the pair.**
A pod's `/sys/class/net/eth0/iflink` holds the node-side interface's `ifindex`,
and that mapping is the only reliable link between a `veth` name and a workload.

### C4 - Explain the DNAT

**1. `10.96.14.7` exists nowhere as an address.** Check, on every node:

```bash
ip addr | grep 10.96.14.7          # nothing
ip route get 10.96.14.7            # routed via the default route, to nowhere real
```

**A ClusterIP is a fiction maintained by iptables.** No interface owns it, no
host answers ARP for it, and nothing routes to it. It exists only as a match
condition in a rule — which is why you cannot ping most ClusterIPs and why
"the Service IP does not respond to ping" is not a fault.

**2. The rules:**

```bash
iptables -t nat -S | grep 10.96.14.7
iptables -t nat -S KUBE-SERVICES | grep web
iptables -t nat -S KUBE-SVC-XXXXXXXX
iptables -t nat -S KUBE-SEP-YYYYYYYY
```

Three layers, and the shape is always the same:

```
KUBE-SERVICES   -d 10.96.14.7/32 --dport 80  -j KUBE-SVC-XXXX
KUBE-SVC-XXXX   -m statistic --mode random --probability 0.5  -j KUBE-SEP-AAAA
KUBE-SVC-XXXX                                                 -j KUBE-SEP-BBBB
KUBE-SEP-AAAA   -j DNAT --to-destination 10.244.1.5:8080
KUBE-SEP-BBBB   -j DNAT --to-destination 10.244.2.9:8080
```

**One destination becomes two backends through `-m statistic --mode random`.**
The first endpoint rule fires with probability 1/N; if it does not match, the
packet falls through to the next, which fires with probability 1/(N-1), and so
on. The last has no probability at all — it is the fallthrough. That arithmetic
is what makes the distribution even.

**It is per *connection*, not per packet**, because conntrack records the
translation and every subsequent packet of that flow follows the same path:

```bash
conntrack -L | grep 10.96.14.7
```

**3. `PREROUTING`, via the `KUBE-SERVICES` chain**, because the destination must
be rewritten **before the routing decision** (21.6). At `PREROUTING` time the
kernel has not yet decided where the packet is going; rewriting the destination
there means it is then routed toward the real pod. Doing it in `POSTROUTING`
would be too late — the routing decision would already have been made for an
address that goes nowhere.

(`KUBE-SERVICES` is also called from `OUTPUT`, so that traffic originating **on
the node itself** — a kubelet health check, a pod on this node calling a
Service — is translated too. `PREROUTING` only sees traffic arriving from
elsewhere.)

**4. With `NodePort`, one chain is added.** Everything above stays; in addition:

```
KUBE-NODEPORTS  -p tcp --dport 31234  -j KUBE-EXT-XXXX  -> KUBE-SVC-XXXX
```

so a packet arriving on **any node's IP** at port 31234 lands in the same
service chain. Two further differences worth knowing: the node port is opened on
every node whether or not a backing pod runs there, and traffic arriving on a
node with no local endpoint is **SNAT'd** as it is forwarded to another node —
which is why `externalTrafficPolicy: Local` exists, and why the client IP is
often lost without it.

### C5 - Rebuild a broken node

*Intra*-node traffic works, so the namespaces, veths and bridge are fine. The
break is in **forwarding or routing off the node**.

**1. `ip_forward`**

```bash
sysctl net.ipv4.ip_forward
```
Healthy: `net.ipv4.ip_forward = 1`.

**2. Routes to the other nodes' pod CIDRs**

```bash
ip route | grep 10.244
```
Healthy: one `via <node-ip>` line per other node, plus the local
`10.244.x.0/24 dev cni0`.

**3. The MASQUERADE rule for egress**

```bash
iptables -t nat -S POSTROUTING | grep -i masq
```
Healthy: a rule masquerading pod-CIDR traffic leaving the node (often
`KUBE-POSTROUTING` or a CNI-specific chain).

**4. `FORWARD` policy and rules**

```bash
iptables -S FORWARD | head
```
Healthy: policy `ACCEPT`, or explicit `ACCEPT` rules for the pod CIDR. **A
`FORWARD` policy of `DROP` with no matching rule is a classic cause** — Docker
sets it, and a CNI that expects to add its own rules and did not leaves the node
in exactly this state.

**5. The node's own external connectivity**

```bash
ip route get 8.8.8.8
ping -c1 <another-node-ip>
```
Healthy: a default route via the real gateway, and other nodes reachable.

**The most likely cause, given that intra-node traffic works: number 2 or number
4.** Both fail exactly this way and nothing else does.

Between them, the deciding evidence is whether **other nodes' pods** and **the
internet** fail together or separately:

- **both broken** → forwarding itself (1 or 4), since every packet leaving the
  bridge for anywhere is affected
- **other nodes' pods broken, internet fine** → the per-node routes (2) are
  missing, which is the signature of a CNI that restarted without re-adding them
- **internet broken, other nodes' pods fine** → the MASQUERADE rule (3)

Note what is *not* on this list: the CNI pod's status. It is `Running` and the
node is `Ready`, and neither of those checks whether the routes it installed are
still present. **`Ready` means the kubelet is happy, not that packets move.**

---

## Files

| File | Purpose |
|---|---|
| `run-in-node.sh` | copy a script into a kind node and run it there |
| `netns-lab.sh` | build the whole thing by hand: namespaces, veth, bridge, route, NAT, DNAT |
| `netns-clean.sh` | remove **only** what the lab created |
| `inspect-pod-network.sh` | show the same primitives as Kubernetes built them |
| `verify.sh` | checks the hand-built network and the node's real one |

There are no `.yaml` files here. **None of this is an API object** — it is
kernel state on a node, which is exactly the point of the assignment.

---

## Why the lab runs inside a kind node

Network namespaces, bridges and iptables rules are **per host**. There is no way
to demonstrate them from `kubectl`, and running them on your workstation would
mean asking you to reconfigure your own machine's networking — on Windows or
macOS, impossible; on Linux, unwise.

A kind node is the ideal target: it is a real Linux host with a real kernel, it
runs privileged so `ip netns` and `iptables` work, **and it already has
Kubernetes networking configured on it** — so the hand-built version and the
real one sit side by side on the same machine and can be compared directly.

`netns-lab.sh` uses `192.168.15.0/24` deliberately: it does not overlap the
kind Docker network (`172.18.0.0/16`) or the pod CIDR (`10.244.0.0/16`), so
nothing it creates can interfere with the cluster.

`netns-clean.sh` deletes objects **by name** rather than by pattern. It will
never remove a `cni0` bridge, a `veth` belonging to a pod, or a `KUBE-` iptables
rule. If you would rather be certain, run the whole assignment against
`devops-worker2` and recreate the cluster afterwards.

## What is deliberately not here

**The CNI plugin itself.** Watching a plugin do this work — the `ADD` and `DEL`
operations, the config in `/etc/cni/net.d/`, the binaries in `/opt/cni/bin/` —
is [CKA 22](../../22-pod-networking-and-cni/)'s subject. This assignment stops at the
primitives so that CKA 22 can be about the automation rather than about veth
pairs.

**IPv6 and dual-stack.** Every command here has an IPv6 equivalent (`ip -6
route`, `ip6tables`), and the concepts are unchanged. The exam is IPv4.

**`nftables`.** Most distributions now use `nftables` under an `iptables-nft`
compatibility layer, so `iptables -S` still works and still prints what you
expect. kube-proxy has an `nftables` mode as an alternative to `iptables` mode.
When `iptables -S` on a modern node shows nothing you recognise, `nft list
ruleset` is the command you want.
