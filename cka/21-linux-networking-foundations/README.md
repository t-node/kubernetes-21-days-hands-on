# CKA 21 — Linux Networking Foundations

**Time:** 100-120 minutes
**Prerequisites:** [Day 06](../../days/day-06-services-clusterip-and-dns/), [CKA 02](../02-container-runtimes-and-crictl/), [CKA 18](../18-network-policies/)
**Source lectures:** 202, 203, 204, 206, 208

Kubernetes networking is not magic and it is barely even Kubernetes. It is Linux
network namespaces, veth pairs, a bridge, some routes and some iptables rules —
the same primitives Docker used before Kubernetes existed.

**You will build the whole thing by hand inside a kind node**, then look at what
Kubernetes built on the same machine and recognise every piece.

---

## Part 1 - Concepts

### 21.1 Interfaces, switches, addresses

Two machines on one network need an **interface** each and a **switch** between
them:

```
  A (192.168.1.10)  ---eth0---+
                              [ SWITCH ]  network 192.168.1.0/24
  B (192.168.1.11)  ---eth0---+
```

```bash
ip link                       # the interfaces, and whether they are UP
ip addr                       # the addresses on them
ip addr add 192.168.1.10/24 dev eth0
ip link set dev eth0 up
```

**A switch only moves packets within one network.** It has no idea what to do
with a packet for `192.168.2.5`.

> **`ip link`, `ip addr` and `ip route` changes do not survive a reboot.** They
> are runtime state. Persisting them is the distribution's job —
> `/etc/network/interfaces`, netplan, NetworkManager, systemd-networkd.

### 21.2 Routes and gateways

To reach another network you need a **router**, and the systems must be told where
it is. That is a **route**:

```bash
ip route                              # the kernel routing table
ip route add 192.168.2.0/24 via 192.168.1.1
ip route add default via 192.168.1.1
```

**If the network is a room, the gateway is the door.** A host with no route to a
destination answers immediately:

```
connect: Network is unreachable
```

That message means the kernel never sent a packet. **It is a routing problem, not
a firewall problem and not a remote problem** — a distinction worth making
instantly, because it eliminates two thirds of what you might otherwise check.

**`default` and `0.0.0.0/0` are the same thing**: "anything I have no more
specific route for". Most hosts need exactly one such entry.

The kernel picks the **most specific** matching route, so a `/24` beats the
default, and `0.0.0.0` in the *gateway* column means "no gateway needed — this
network is directly attached".

### 21.3 A Linux host as a router

Give a host two interfaces on two networks and it *could* route between them. By
default it will not:

```bash
cat /proc/sys/net/ipv4/ip_forward       # 0 -- packets are not forwarded
echo 1 > /proc/sys/net/ipv4/ip_forward  # runtime only
```

To persist it, `net.ipv4.ip_forward = 1` in `/etc/sysctl.conf`.

**Forwarding is off by default for a reason:** a host with one foot in a private
network and one on the internet would otherwise silently bridge them.

**Every Kubernetes node has this enabled.** It has to — pod traffic arrives on
one interface and leaves on another. It is the first thing to check when pods on
a node can reach nothing.

### 21.4 DNS

Two files decide how a Linux host resolves a name:

```bash
cat /etc/hosts        # static entries, checked FIRST
cat /etc/resolv.conf  # which server to ask, and what to append
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

| Directive | Effect |
|---|---|
| `nameserver` | who to ask (up to 3, tried in order) |
| `search` | suffixes appended to a **short** name, in order |
| `options ndots:N` | a name with **fewer than N dots** is tried with the search suffixes *first* |

**`ndots:5` is the Kubernetes-specific part and it explains a lot of behaviour.**
`db` has 0 dots, so it is tried as `db.default.svc.cluster.local`, then
`db.svc.cluster.local`, then `db.cluster.local`, and only then as `db` itself.
That is what makes short Service names work — and it is why looking up
`www.google.com` (3 dots, still under 5) costs three failed queries first.

Record types you need:

| Type | Maps |
|---|---|
| `A` | name -> IPv4 |
| `AAAA` | name -> IPv6 |
| `CNAME` | name -> another name |
| `SRV` | service -> host **and port** (headless Services, [Day 15](../../days/day-15-statefulsets-and-headless-services/)) |
| `PTR` | IP -> name (reverse) |

```bash
nslookup kubernetes.default
dig +short kubernetes.default.svc.cluster.local
dig SRV _http._tcp.my-svc.default.svc.cluster.local
getent hosts db          # what the SYSTEM resolves, /etc/hosts included
```

> **`dig` and `nslookup` ignore `/etc/hosts`.** They talk to the DNS server
> directly. `getent hosts` follows the full system path. When an application
> resolves a name differently from `dig`, that difference is usually the answer.

### 21.5 Network namespaces

A **network namespace** is a private copy of the entire network stack:
interfaces, routes, ARP table, iptables rules, sockets.

```bash
ip netns add red
ip netns list
ip netns exec red ip link      # only `lo` -- it can see nothing of the host
ip -n red link                 # shorthand for the same thing
```

**That is what a container is, network-wise.** No interfaces, no routes, no
visibility of the host — which is also why a fresh namespace can reach nothing at
all.

To connect two namespaces you need a **veth pair** — a virtual cable with an
interface at each end:

```bash
ip link add veth-red type veth peer name veth-blue
ip link set veth-red netns red
ip link set veth-blue netns blue
ip -n red addr add 192.168.15.1/24 dev veth-red
ip -n red link set veth-red up
```

**Whatever goes in one end comes out the other.** Delete one end and the other
disappears — they are a pair, not two objects.

That works for two namespaces. For many, you need a switch, and the Linux one is
a **bridge**:

```
                   +-------------------+
   red  --veth-----|                   |
   blue --veth-----|  bridge  v-net-0  |----- the host
   green --veth----|                   |
                   +-------------------+
```

```bash
ip link add v-net-0 type bridge
ip link set dev v-net-0 up
ip link set veth-red-br master v-net-0     # plug a cable into the switch
```

**The bridge is a switch to the namespaces and an interface to the host.** That
dual nature is the key idea: give the bridge an IP address and the host itself
joins the namespaces' network.

### 21.6 Getting out, and getting in

A namespace on `192.168.15.0/24` cannot reach the LAN even with a route, because
the LAN has never heard of that network and cannot reply. You need **NAT**:

```bash
iptables -t nat -A POSTROUTING -s 192.168.15.0/24 -j MASQUERADE
```

**MASQUERADE rewrites the source address to the host's own**, so replies come
back to the host, which un-rewrites them. Every home router does this.

The reverse — reaching *into* a namespace from outside — is **DNAT**:

```bash
iptables -t nat -A PREROUTING -p tcp --dport 8080 \
  -j DNAT --to-destination 192.168.15.2:80
```

| Chain | When | Used for |
|---|---|---|
| `PREROUTING` | before the routing decision | **DNAT** — changing the destination |
| `POSTROUTING` | after it, on the way out | **SNAT / MASQUERADE** — changing the source |

**That is exactly what `docker run -p 8080:80` does**, and it is the shape of
what kube-proxy does for a NodePort.

### 21.7 The map to Kubernetes

Everything above appears, unchanged, on a Kubernetes node:

| Linux primitive | In Kubernetes |
|---|---|
| network namespace | **a pod** — all its containers share one |
| veth pair | one end in the pod, one on the node |
| bridge | the CNI's bridge (`cni0`, `docker0`, ...) |
| route on the node | how to reach pods on *other* nodes |
| `ip_forward=1` | mandatory on every node |
| MASQUERADE | pod traffic leaving the cluster |
| DNAT in PREROUTING | **Services** — kube-proxy's rules |
| `/etc/resolv.conf` | injected into every pod, pointing at CoreDNS |

**A CNI plugin's entire job is to create the namespace's interface, address it,
and wire it to the bridge.** In Part 2 you do that by hand first, so the
automated version has nothing left to be mysterious about.

---

## Part 2 - Hands-on lab

**Everything here happens inside a kind node**, because that is where the
namespaces, bridges and iptables rules live. A kind node is an ordinary
privileged Linux host:

```bash
docker exec -it devops-worker bash
```

Every command below can be run in that shell, or from your workstation with
`docker exec devops-worker <command>`.

### Step 1: Read the node's own networking

```bash
docker exec devops-worker ip -br addr
docker exec devops-worker ip route
docker exec devops-worker cat /proc/sys/net/ipv4/ip_forward
```

```
lo               UNKNOWN  127.0.0.1/8
eth0@if15        UP       172.18.0.4/16
...
default via 172.18.0.1 dev eth0
10.244.0.0/24 via 172.18.0.2 dev eth0
10.244.2.0/24 via 172.18.0.3 dev eth0
```

Read those routes carefully — they are the whole of "flat pod networking":

- `default via 172.18.0.1` — the Docker network's gateway, for anything outside
- **`10.244.0.0/24 via 172.18.0.2`** — *"pods on the control-plane node are
  reachable through that node's IP"*
- one such line **per other node**

**No tunnels, no overlay, no encapsulation.** Each node owns a `/24` of the pod
network and every other node has a route to it. `ip_forward` is `1`, or none of
this would work (21.3).

```bash
docker exec devops-worker ip -br link show type bridge
docker exec devops-worker ip -br link show type veth | head
```

**A bridge, and a pile of veth interfaces — one per pod on this node.** By the
end of Part 2 you will have created both kinds by hand.

### Step 2: Build it yourself

Read the script before running it. It is six steps and it prints each one:

```bash
cat solution/netns-lab.sh
bash solution/run-in-node.sh netns-lab.sh
```

Work through the output against 21.5 and 21.6:

**1. Two namespaces.** `ip -n red link` shows only `lo`. A container's network,
before anything is wired up, is *nothing at all*.

**2. A veth pair.** `red` pings `blue` and the ARP table on each learns the
other — while the **host's** ARP table knows nothing about either. That is the
isolation.

**3. A bridge.** The direct cable is deleted and both namespaces are plugged
into a switch instead. `ip link show master v-net-0` lists what is connected.

**4. An address on the bridge.** Now the *host* can ping into the namespaces —
because the bridge is a switch to them and an interface to it (21.5).

**5. A route and MASQUERADE.** Before: `Network is unreachable`, the exact
message from 21.2. After: a default gateway and a source-NAT rule, and traffic
gets out.

**6. DNAT.** One rule in `PREROUTING` sends port 8080 on the node into a
namespace on port 80. **That is a NodePort, without Kubernetes.**

Poke at it yourself:

```bash
docker exec devops-worker ip netns list
docker exec devops-worker ip -n red addr
docker exec devops-worker ip -n red route
docker exec devops-worker ip netns exec red ping -c2 192.168.15.2
docker exec devops-worker iptables -t nat -L POSTROUTING -n | head
```

Try breaking it, which is the useful half:

```bash
# remove red's default route -- what error comes back?
docker exec devops-worker ip -n red route del default
docker exec devops-worker ip netns exec red ping -c1 -W1 8.8.8.8
docker exec devops-worker ip -n red route add default via 192.168.15.5

# take the bridge down and watch namespace-to-namespace traffic stop
docker exec devops-worker ip link set v-net-0 down
docker exec devops-worker ip netns exec red ping -c1 -W1 192.168.15.2
docker exec devops-worker ip link set v-net-0 up
```

**`Network is unreachable` versus a timeout.** The first means no route existed;
the second means the packet left and nothing came back. Two different problems
and two different next steps — this is the single most useful distinction in
network debugging.

### Step 3: Now look at the real thing

```bash
bash solution/run-in-node.sh inspect-pod-network.sh
```

Section by section, against what you just built:

| The script shows | You built it in |
|---|---|
| the node's routes, one per other node | step 5 (a route to another network) |
| `ip_forward = 1` | step 5 |
| a bridge | step 3 |
| dozens of veth interfaces | step 3 |
| a pod's namespace entered with `nsenter` | step 1 |
| the pod's default route pointing at the bridge | step 5 |
| `PREROUTING` DNAT rules from kube-proxy | step 6 |

The `eth0@ifNN` detail is worth pausing on:

```bash
docker exec devops-worker sh -c 'ip -o link | grep veth | head -3'
```

**Every veth interface names its peer's index.** `eth0@if12` inside a pod means
"my other end is interface 12 on the host" — which is how you match a mystery
`vethabc123` on a busy node to the pod it belongs to.

### Step 4: DNS from the inside

```bash
kubectl run dnstest --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/dnstest --timeout=60s
kubectl exec dnstest -- cat /etc/resolv.conf
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

**None of that was in the image.** The kubelet writes it into every pod (21.4).
Watch the search path do its work:

```bash
kubectl exec dnstest -- nslookup kubernetes 2>&1 | head -8
kubectl exec dnstest -- nslookup kubernetes.default.svc.cluster.local 2>&1 | head -8
```

Both resolve — the first because `search` appended the suffix. Now the cost of
`ndots:5`:

```bash
kubectl exec dnstest -- nslookup www.google.com 2>&1 | head -12
```

`www.google.com` has three dots, fewer than five, so it is tried as
`www.google.com.default.svc.cluster.local` first, then two more suffixes, and
only then as itself. **Three failed queries before the one that works** — the
reason `ndots` appears in every Kubernetes DNS performance discussion, and the
reason a trailing dot (`www.google.com.`) short-circuits it.

```bash
kubectl exec dnstest -- nslookup 10-244-1-5.default.pod.cluster.local 2>&1 | tail -4
kubectl get svc -n kube-system kube-dns
```

**`10.96.0.10` is a Service ClusterIP**, so DNS itself is reached through the
DNAT rules from step 6 — the resolver's first packet is already being rewritten
by iptables.

```bash
kubectl delete pod dnstest --force --grace-period=0 2>/dev/null
```

### Cleanup

```bash
bash solution/run-in-node.sh netns-clean.sh
docker exec devops-worker ip netns list
```

The script removes **only** what the lab created. Kubernetes' own namespaces,
bridge and iptables rules are untouched.

---

## Part 3 - Challenges

### C1 - Read a routing table

```
default via 10.0.0.1 dev eth0
10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.15
10.244.1.0/24 dev cni0 proto kernel scope link src 10.244.1.1
10.244.0.0/24 via 10.0.0.11 dev eth0
10.244.2.0/24 via 10.0.0.12 dev eth0
```

Answer from that table alone:

1. What is this node's own IP, and what is its pod CIDR?
2. How many other nodes does this cluster have, and what are their IPs?
3. A pod on this node sends a packet to `10.244.2.7`. Trace the decision.
4. The same pod sends to `8.8.8.8`. Trace it, and say what else must be true for
   a reply to arrive.
5. Which single line would you delete to make this node unable to reach pods on
   one other node — and what would the symptom look like to a user?

### C2 - Two failures that look the same

A pod cannot reach `10.96.0.10`. In one case `ping` says
`Network is unreachable`; in the other it times out.

For each: what has failed, what is the next command, and which of the two is
*not* a Kubernetes problem at all? Then give the one `ip` command that
distinguishes them in under a second.

### C3 - Match the veth

A node has 40 `veth*` interfaces and one is generating errors. Given the
interface name `veth7a3f21@if8`, give the commands to find **which pod** it
belongs to. Do it two ways: from the interface to the pod, and from a known pod
to its interface.

### C4 - Explain the DNAT

`kubectl get svc web` shows ClusterIP `10.96.14.7:80`, with two endpoints.

1. Where does `10.96.14.7` exist as an address? (It is not on any interface —
   check.)
2. Show the iptables rules that make it work, and explain how one destination
   becomes two backends.
3. Which chain, and why that one rather than the other.
4. What changes if the Service is `NodePort` instead?

### C5 - Rebuild a broken node

A node's pods can talk to each other but cannot reach pods on other nodes or the
internet. `kubectl` shows the node `Ready` and the CNI pod `Running`.

List, in order, the five things you would check with `ip` and `sysctl`, what a
healthy answer looks like for each, and which single one is most likely given
that *intra*-node traffic works.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Run it **after** `netns-lab.sh` and **before** `netns-clean.sh`. It checks that
both namespaces exist and can reach each other through the bridge, that the
bridge carries an address, that the namespaces have a default route and a
MASQUERADE rule, that the DNAT rule is present — and then that the node's own
Kubernetes networking has the routes, forwarding and veth pairs it should.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# interfaces and addresses, briefly
ip -br addr
ip -br link
ip -br link show type veth
ip -br link show type bridge

# routes
ip route
ip route get 10.244.2.7          # which route WOULD be used -- excellent
ip route add 10.244.2.0/24 via 10.0.0.12
ip route del default

# forwarding
sysctl net.ipv4.ip_forward
cat /proc/sys/net/ipv4/ip_forward

# namespaces
ip netns list
ip -n red addr
ip netns exec red ip route
nsenter -t <pid> -n ip addr      # enter a namespace by PID, not by name

# NAT
iptables -t nat -L -n --line-numbers
iptables -t nat -S | grep KUBE-SVC
conntrack -L 2>/dev/null | head  # what is actually being translated

# DNS
cat /etc/resolv.conf
nslookup <name>
dig +short <name>
getent hosts <name>              # follows /etc/hosts too
```

**`ip route get <ip>` is the single most useful command here** — it asks the
kernel which route it *would* choose, rather than making you read the table.

**Traps**

- **`Network is unreachable` is a routing failure**, not a firewall or a remote
  failure. The packet never left.
- **A timeout means the packet left.** Look at the far end, at NAT, or at
  policy.
- **`ip` changes do not persist a reboot.**
- **`ip_forward` must be 1** on every node. Check it first when a node's pods
  cannot leave it.
- **A veth pair is one object.** Delete either end and both go.
- **`eth0@if12` names the peer's index** — that is how you match a pod to its
  host-side interface.
- **The bridge is an interface to the host and a switch to the namespaces.**
  Give it an address to join their network.
- **MASQUERADE is `POSTROUTING`; DNAT is `PREROUTING`.** Getting them the wrong
  way round produces rules that never match.
- **`ndots:5` makes short names cheap and long names expensive.** A trailing dot
  bypasses the search list.
- **`dig` ignores `/etc/hosts`; `getent hosts` does not.** When they disagree,
  that is the finding.
- **A ClusterIP is not on any interface.** It exists only as an iptables rule.

---

**Previous:** [CKA 20 — Storage Internals, Provisioners and CSI](../20-storage-internals-and-csi/)
**Next: CKA 22 — Pod Networking and CNI** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
