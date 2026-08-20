# CKA 22 — Pod Networking and CNI

**Time:** 90-110 minutes
**Prerequisites:** [CKA 21](../21-linux-networking-foundations/), [CKA 02](../02-container-runtimes-and-crictl/), [CKA 18](../18-network-policies/)
**Source lectures:** 209, 210, 213, 214, 215, 217, 219, 220

[CKA 21](../21-linux-networking-foundations/) had you build a pod's network by
hand — namespace, veth, bridge, address, route, NAT. This assignment is about
**the program that does that for you**: where it lives, how it is invoked, and
what happens when it is not there.

---

## Part 1 - Concepts

### 22.1 The Kubernetes network model is four sentences

Kubernetes does not implement pod networking. It **specifies** it, and requires
that whatever you install satisfies these:

1. **Every pod gets its own unique IP address.**
2. **Every pod can reach every pod on the same node** using that address.
3. **Every pod can reach every pod on every other node** using that address.
4. **Without NAT.** The address the receiver sees is the sender's real pod IP.

That is the whole contract. Kubernetes does not care what range, what topology,
or what mechanism.

**Requirement 4 is the demanding one.** It rules out the port-mapping approach
Docker used by default, and it is why "pods can just talk to each other" feels
different from ordinary container networking.

You verified all four in [CKA 21](../21-linux-networking-foundations/) by reading
one routing table: a `/24` per node and a `via` route to each of the others.

### 22.2 Why CNI exists

Every container platform solved this the same way — namespace, veth, bridge,
IPAM, NAT — and every one wrote its own code for it. So the work was factored out
into **a program**:

```bash
/opt/cni/bin/bridge            # "attach this namespace to a bridge"
```

and then into a **standard** describing how such programs are written and
invoked. That standard is the **Container Network Interface**.

| Party | Responsibility |
|---|---|
| **the runtime** (containerd, CRI-O) | create the network namespace; decide which network the container joins; **invoke the plugin** with `ADD` on create and `DEL` on delete |
| **the plugin** | create the interface, assign an IP, set up routes, return a result in a defined JSON format |

**Same pattern as CRI and CSI** ([CKA 02](../02-container-runtimes-and-crictl/),
[CKA 20](../20-storage-internals-and-csi/)): a specification instead of an
integration, so any runtime works with any plugin.

> **Docker is the exception.** It implements **CNM** (Container Network Model),
> not CNI, which is why you cannot hand a CNI plugin to `docker run`. Kubernetes
> works around it by creating the container with no network and invoking the
> plugin itself — exactly what you do by hand in Step 4.

### 22.3 A plugin is a binary that reads stdin

The interface is deliberately primitive: **environment variables plus JSON on
stdin, JSON on stdout.**

| Variable | Meaning |
|---|---|
| `CNI_COMMAND` | `ADD`, `DEL`, `CHECK` or `VERSION` |
| `CNI_CONTAINERID` | an opaque id the runtime chooses |
| `CNI_NETNS` | path to the network namespace, e.g. `/var/run/netns/demo` |
| `CNI_IFNAME` | what to call the interface inside it — normally `eth0` |
| `CNI_PATH` | where to find other plugin binaries |

```bash
CNI_COMMAND=ADD CNI_CONTAINERID=demo CNI_NETNS=/var/run/netns/demo \
CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin \
  /opt/cni/bin/bridge < net.json
```

It prints a result naming the interfaces it made, the addresses assigned and the
routes added. **There is no daemon and no API** — the runtime forks a process per
container, per operation.

### 22.4 Two directories

```
/opt/cni/bin/          the plugin BINARIES
/etc/cni/net.d/        the CONFIGURATION -- which plugin, and how
```

Both are read by the **container runtime**, not by the kubelet.

```bash
ls /opt/cni/bin/
# bridge  dhcp  host-local  ipvlan  loopback  macvlan  portmap  ptp  tuning ...

ls /etc/cni/net.d/
# 10-kindnet.conflist
```

**If several config files exist, the first in alphabetical order wins** — which
is why every one of them starts with a number. A leftover `05-something.conf`
silently takes precedence over the file you just edited.

Two file types:

| Extension | Contains |
|---|---|
| `.conf` | **one** plugin |
| `.conflist` | a **chain** of plugins, run in order |

```json
{
  "cniVersion": "0.4.0",
  "name": "kindnet",
  "plugins": [
    { "type": "ptp", "ipMasq": false, "ipam": { "type": "host-local" } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

**Chaining is how one plugin does the network and others add features.** The
first entry creates the interface; `portmap` then adds the DNAT rules that make
`hostPort` work, `bandwidth` adds traffic shaping, `firewall` adds rules. Each is
a separate binary, run in sequence, receiving the previous one's result.

The fields map straight onto [CKA 21](../21-linux-networking-foundations/):

| Field | What it does |
|---|---|
| `type` | which binary in `/opt/cni/bin` to run |
| `isGateway` | give the bridge an IP so it can be the pods' gateway (21.5) |
| `ipMasq` | add the MASQUERADE rule (21.6) |
| `ipam` | how addresses are allocated |

### 22.5 IPAM is a separate plugin

```json
  "ipam": {
    "type": "host-local",
    "ranges": [[{ "subnet": "10.244.1.0/24" }]],
    "routes": [{ "dst": "0.0.0.0/0" }]
  }
```

| IPAM type | Allocates from |
|---|---|
| `host-local` | a range, tracked **in files on this node** |
| `dhcp` | a real DHCP server on the network |
| `static` | a fixed address you supply |

**`host-local` keeps its state on disk**, and it is worth knowing where:

```bash
ls /var/lib/cni/networks/<network-name>/
# 10.244.1.2  10.244.1.3  last_reserved_ip.0  lock
```

**One file per allocated address, containing the container ID that holds it.**
That is the entire database. When a node "runs out of pod IPs" with barely any
pods running, this directory holds the stale entries — a known failure after an
unclean kubelet restart, and the fix is deleting the orphaned files.

### 22.6 Who calls the plugin

```
   kubelet
     |  CRI: RunPodSandbox
     v
   containerd
     |  creates the network namespace
     |  reads /etc/cni/net.d, runs /opt/cni/bin/<type>
     v
   CNI plugin  ->  veth, address, routes
```

**The kubelet does not call CNI.** It asks the runtime for a sandbox; the runtime
does the networking. The old `--network-plugin=cni`, `--cni-conf-dir` and
`--cni-bin-dir` kubelet flags are **gone** — the paths now live in the runtime's
configuration:

```bash
grep -A3 cni /etc/containerd/config.toml
```

**This is why "the CNI is broken" surfaces as a kubelet complaint about the
runtime**, and why `crictl` ([CKA 02](../02-container-runtimes-and-crictl/)) is
the right tool for diagnosing it.

The kubelet does report the result:

```
NotReady   container runtime network not ready: NetworkReady=false
           reason:NetworkPluginNotReady message:Network plugin returns error:
           cni plugin not initialized
```

**A node with no CNI configuration is `NotReady`** — and that message names the
exact problem, if you read past the first line.

### 22.7 Routed or encapsulated

Two ways to satisfy requirement 3:

| Approach | How | Cost |
|---|---|---|
| **Routed** | a route per node, as in [CKA 21](../21-linux-networking-foundations/) | none — plain IP |
| **Overlay** | wrap each packet in VXLAN or IPIP | ~50 bytes per packet, plus MTU trouble |

**Routed is better and is not always possible.** It requires the underlying
network to carry packets whose source and destination are pod addresses — fine on
a flat L2 network or where you can program the router, impossible on most cloud
networks, which drop packets with unknown source addresses.

kind is routed, and you can prove it in one command:

```bash
ip -d link show type vxlan          # nothing
ip route | grep 10.244              # plain via routes
```

**If you see `flannel.1`, `vxlan.calico` or `tunl0`, you are on an overlay** —
and MTU becomes something you must think about, because the encapsulation header
eats into the 1500 bytes the pod believes it has.

### 22.8 The node's own network requirements

Before pods, the nodes have to work:

| Port | Component |
|---|---|
| **6443** | kube-apiserver |
| **10250** | kubelet (every node) |
| **10257** | kube-controller-manager |
| **10259** | kube-scheduler |
| **2379** | etcd clients |
| **2380** | etcd peers |
| **30000-32767** | NodePort range, on **every** node |

Plus a **unique hostname** and a **unique MAC address** per node.

> **The MAC one bites people who clone VMs.** Two nodes with the same MAC, or the
> same `/etc/machine-id`, give you a cluster that works intermittently and is
> maddening to diagnose. Check both on a cloned node before anything else.

---

## Part 2 - Hands-on lab

As in [CKA 21](../21-linux-networking-foundations/), most of this happens inside
a node — CNI is files and binaries on a host, not API objects.

### Step 1: Everything CNI on this node

```bash
bash solution/run-in-node.sh cni-explore.sh
```

Nine sections. Read them against Part 1:

**1 and 2** — the binaries and the configuration (22.4). Note the leading `10-`
on the config filename and that **the first file alphabetically wins**.

**3** — the plugin chain. On kind you will see something like `ptp` then
`portmap`: one plugin makes the interface, another adds `hostPort` DNAT.

**4** — the IPAM database (22.5). One file per address, each containing the
container id holding it. **That is the whole thing** — no daemon, no etcd entry.

**5** — where containerd was told to look (22.6).

**6** — routed or overlay (22.7). kind has no `vxlan` and no `tunl0`, so those
`via` routes are the entire cross-node mechanism.

**8 and 9** — hostname, machine-id, MAC, and the control-plane ports (22.8). Run
it against `devops-control-plane` too and compare section 9:

```bash
NODE=devops-control-plane bash solution/run-in-node.sh cni-explore.sh
```

### Step 2: Watch an ADD happen

Capture the "before", create a pod, capture the "after":

```bash
docker exec devops-worker sh -c 'ls /var/lib/cni/networks/*/ | grep -c "^10\." ' 
docker exec devops-worker sh -c 'ip -br link show type veth | wc -l'

kubectl run cniwatch --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"devops-worker"}}' -- sleep 3600
kubectl wait --for=condition=Ready pod/cniwatch --timeout=60s

docker exec devops-worker sh -c 'ls /var/lib/cni/networks/*/ | grep -c "^10\." '
docker exec devops-worker sh -c 'ip -br link show type veth | wc -l'
```

**Both counts went up by one.** Now find *this* pod's allocation:

```bash
POD_IP=$(kubectl get pod cniwatch -o jsonpath='{.status.podIP}')
echo "$POD_IP"
docker exec devops-worker sh -c "cat /var/lib/cni/networks/*/${POD_IP}"
```

That file contains the **container id** — the same `CNI_CONTAINERID` the runtime
passed the plugin (22.3):

```bash
docker exec devops-worker crictl ps --name cniwatch -o json 2>/dev/null | grep -m1 podSandboxId
```

Now delete the pod and watch `DEL` reverse it:

```bash
kubectl delete pod cniwatch --force --grace-period=0 2>/dev/null
sleep 5
docker exec devops-worker sh -c "ls /var/lib/cni/networks/*/${POD_IP} 2>&1"
```

```
ls: cannot access '/var/lib/cni/networks/kindnet/10.244.1.7': No such file or directory
```

**The address was released because the plugin's `DEL` succeeded.** When `DEL`
fails — a crashed plugin, a node that lost power — that file stays, the address
is never reused, and eventually the node cannot start pods despite running very
few. That is the failure mode 22.5 warned about, and the fix is deleting the
orphaned files.

### Step 3: Invoke a plugin the way containerd does

This is the exercise worth doing slowly.

```bash
cat solution/cni-by-hand.sh
bash solution/run-in-node.sh cni-by-hand.sh add
```

Six sections:

**1 — the runtime's job.** A namespace is created and, before the plugin runs,
`ip -n cnidemo addr` shows nothing but `lo`. Exactly the state
[CKA 21](../21-linux-networking-foundations/) started from.

**2 — the plugin's job.** Five environment variables and a JSON config on stdin.
The output is the **CNI Result**: the interfaces, the address, the routes. That
JSON is what containerd parses to learn the pod's IP.

**3 and 4 — what it actually did.** An interface with an address, a default
route, a veth on the host side, and a MASQUERADE rule from `"ipMasq": true`.
**Every one of those you created by hand in CKA 21**; here one binary did all of
it from a fifteen-line config.

**5 — IPAM state on disk**, in a directory named after the network.

**6 — it works.** The namespace pings its gateway.

Then reverse it, and watch the address come back:

```bash
bash solution/run-in-node.sh cni-by-hand.sh del
```

> **Note what was not involved:** no kubelet, no containerd, no API server, no
> pod. A CNI plugin is a program you can run from a shell, which is why
> debugging one means running it from a shell.

### Step 4: Break the CNI

```bash
bash solution/run-in-node.sh break-cni.sh break
```

Then, from your workstation:

```bash
kubectl get nodes -w        # devops-worker goes NotReady in ~30s; Ctrl-C
kubectl describe node devops-worker | grep -B2 -A4 "NetworkReady"
```

```
Ready  False  KubeletNotReady  container runtime network not ready:
NetworkReady=false reason:NetworkPluginNotReady
message:Network plugin returns error: cni plugin not initialized
```

**Read past the first line.** "KubeletNotReady" is the headline and the actual
cause is in the message — and it names the CNI explicitly (22.6).

Now watch what is and is not affected:

```bash
kubectl get pods -A -o wide | grep devops-worker | head
```

**The pods already running there are fine.** Their networking was configured when
they were created and nothing has revisited it. Try a new one:

```bash
kubectl run cnitest --image=nginx:alpine \
  --overrides='{"spec":{"nodeName":"devops-worker"}}'
sleep 15
kubectl get pod cnitest
kubectl describe pod cnitest | grep -A6 Events
```

```
Warning  FailedCreatePodSandBox  ... failed to setup network for sandbox:
plugin type="ptp" failed (add): ...
```

`ContainerCreating`, forever. **The pod was scheduled** — the node was `Ready`
when the scheduler looked — and then could not be created. That gap between
scheduling and sandbox creation is where CNI failures live.

```bash
docker exec devops-worker crictl pods | head -3
bash solution/run-in-node.sh break-cni.sh fix
sleep 30
kubectl get nodes
kubectl get pod cnitest -w        # it starts on its own; Ctrl-C
kubectl delete pod cnitest --force --grace-period=0 2>/dev/null
```

**Nothing had to be re-scheduled.** The kubelet retries sandbox creation, and the
moment the plugin works the pod starts — which is why "restore the config and
wait" is the correct response, not "delete and recreate everything".

### Step 5: Prove requirement 4 — no NAT

```bash
kubectl apply -f solution/01-two-pods.yaml
kubectl wait --for=condition=Ready pod/echo-server pod/echo-client --timeout=90s
kubectl get pods -o wide -l app=nat-test
```

If the two landed on different nodes, this is the interesting case. Ask the
server what source address it saw:

```bash
CLIENT_IP=$(kubectl get pod echo-client -o jsonpath='{.status.podIP}')
SERVER_IP=$(kubectl get pod echo-server -o jsonpath='{.status.podIP}')
echo "client pod IP: $CLIENT_IP"

kubectl exec echo-client -- sh -c "wget -qO- --timeout=5 http://${SERVER_IP}/ >/dev/null 2>&1"
kubectl logs echo-server | tail -3
```

**The nginx access log shows `$CLIENT_IP`, not a node IP.** That is requirement 4
(22.1): pod-to-pod traffic is not NAT'd, even across nodes.

Contrast with traffic leaving the cluster, which **is** masqueraded:

```bash
docker exec devops-worker iptables -t nat -S | grep -i masq | head -3
```

```bash
kubectl delete -f solution/01-two-pods.yaml
```

### Cleanup

```bash
bash solution/run-in-node.sh cni-by-hand.sh del 2>/dev/null
bash solution/run-in-node.sh break-cni.sh fix 2>/dev/null
kubectl get nodes
```

---

## Part 3 - Challenges

### C1 - Read an unfamiliar CNI config

```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "plugins": [
    { "type": "bridge", "bridge": "cni0", "isGateway": true, "ipMasq": true,
      "ipam": { "type": "host-local", "subnet": "10.22.0.0/16",
                "routes": [{ "dst": "0.0.0.0/0" }] } },
    { "type": "portmap", "capabilities": { "portMappings": true } },
    { "type": "bandwidth", "capabilities": { "bandwidth": true } }
  ]
}
```

1. How many binaries run when a pod is created on this node, and in what order?
2. Which of them assigns the IP, and where is that record kept?
3. What does `isGateway: true` cause, in `ip` terms?
4. What breaks if you remove `"ipMasq": true`, and what keeps working?
5. The subnet is a `/16` **per node**. What is wrong with that, and what should
   it be?

### C2 - The node that ran out of IPs

A node with 11 running pods cannot start a twelfth:

```
failed to allocate for range 0: no IP addresses available in range set 10.244.3.0/24
```

1. Explain how a `/24` ran out with 11 pods.
2. Give the commands to confirm it.
3. Give the fix, and the one check you must do **before** applying it.
4. What causes this, and what would prevent it recurring?

### C3 - Overlay or routed

You are handed a cluster and must determine, without documentation, whether pod
traffic is encapsulated.

Give four independent pieces of evidence and the command for each. Then say what
practical difference it makes to (a) MTU, (b) troubleshooting with `tcpdump`,
and (c) whether a firewall between nodes needs a rule change.

### C4 - Order of operations

A pod is `ContainerCreating`. Put these in the order they happen, and say which
step fails for each of the three errors below:

```
a. the kubelet calls RunPodSandbox
b. the scheduler sets spec.nodeName
c. containerd runs /opt/cni/bin/<type> with CNI_COMMAND=ADD
d. containerd creates the network namespace
e. the plugin returns a Result containing the pod IP
f. the kubelet starts the application containers
```

- `cni plugin not initialized`
- `failed to setup network for sandbox: no IP addresses available`
- `ImagePullBackOff`

### C5 - Install a CNI on a bare cluster

You have just run `kubeadm init`. The node is `NotReady` and CoreDNS is
`Pending`.

1. Explain why CoreDNS specifically is `Pending` while other control-plane pods
   are `Running`.
2. Give the sequence to install a CNI and verify it.
3. What must match between the CNI's configuration and what `kubeadm init` was
   given?
4. Name two ways to check it worked that do not involve `kubectl get nodes`.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the plugin binaries and config directory exist and the chain is
readable; the IPAM state directory has one file per pod IP on that node; the
node's routes cover every other node's pod CIDR; `ip_forward` is on; there is no
encapsulation interface on a routed cluster; and a pod's IP appears in the IPAM
database with a container id.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the two directories, always
ls /opt/cni/bin/
ls /etc/cni/net.d/
cat /etc/cni/net.d/*.conflist

# which plugin chain is in use
grep -o '"type": *"[^"]*"' /etc/cni/net.d/*.conflist

# the IPAM database
ls /var/lib/cni/networks/*/
cat /var/lib/cni/networks/*/10.244.1.7      # who holds this address

# which CNI is installed, from the API side
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|flannel|weave|kindnet'
kubectl get daemonset -n kube-system

# why is this node NotReady?
kubectl describe node NAME | grep -A5 -i networkready
kubectl get nodes -o json | jq -r '.items[].status.conditions[] | select(.type=="Ready") | .message'

# routed or overlay?
ip -d link show type vxlan
ip link show tunl0
ip route | grep <pod-cidr>

# invoke a plugin by hand
CNI_COMMAND=ADD CNI_CONTAINERID=x CNI_NETNS=/var/run/netns/x CNI_IFNAME=eth0 \
CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge < conf.json
```

**Traps**

- **Kubernetes does not implement pod networking.** It states four requirements
  and delegates. "No CNI installed" is a valid cluster state, and a `NotReady`
  one.
- **The kubelet does not call CNI** — the **container runtime** does. The old
  `--cni-*` kubelet flags are gone; look in `/etc/containerd/config.toml`.
- **First file alphabetically in `/etc/cni/net.d` wins.** A stale file shadows
  the real one.
- **`.conflist` is a chain**, and each entry is a separate binary.
- **`host-local` IPAM state is files on disk.** Stale files exhaust the range.
- **A missing CNI does not disturb running pods.** It stops new sandboxes and
  makes the node `NotReady`.
- **`ContainerCreating` with `FailedCreatePodSandBox` is a CNI problem;**
  `ImagePullBackOff` never is.
- **Docker uses CNM, not CNI.**
- **A `/24` per node is 254 addresses**, not per cluster. Pod CIDR sizing is
  per node.
- **The pod CIDR given to `kubeadm init` must match the CNI's configuration**, or
  pods get addresses the node routes know nothing about.
- **Overlay means reduced MTU.** A pod that can ping but cannot complete a TLS
  handshake is the classic MTU symptom.

---

**Previous:** [CKA 21 — Linux Networking Foundations](../21-linux-networking-foundations/)
**Next: CKA 23 — Service Networking** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
