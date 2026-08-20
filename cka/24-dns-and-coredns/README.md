# CKA 24 — DNS and CoreDNS

**Time:** 90-110 minutes
**Prerequisites:** [Day 06](../../days/day-06-services-clusterip-and-dns/), [Day 15](../../days/day-15-statefulsets-and-headless-services/), [CKA 21](../21-linux-networking-foundations/), [CKA 23](../23-service-networking/)
**Source lectures:** 225, 226, 228

Every name a pod resolves goes through one Deployment in `kube-system`. This
assignment is about that Deployment: the naming scheme it implements, the file
that configures it, and what a cluster looks like when it is not working.

---

## Part 1 - Concepts

### 24.1 The naming scheme

**Services** get an A record, always:

```
<service>.<namespace>.svc.cluster.local
```

| From | You can write |
|---|---|
| the same namespace | `web` |
| another namespace | `web.apps` |
| anywhere | `web.apps.svc` or `web.apps.svc.cluster.local` |

The short forms work because of the **search list** in `/etc/resolv.conf`
([CKA 21](../21-linux-networking-foundations/)), not because DNS is clever. There
is exactly one record; the resolver tries suffixes until one matches.

**Pods** get a record too, but not by their name:

```
10-244-1-5.<namespace>.pod.cluster.local
```

**The IP with dots replaced by dashes.** It is nearly useless — you must already
know the address to construct the name — and it is **disabled by default**. Note
that `pod` is a different subdomain from `svc`, so the search list (which only
covers `svc`) never finds it.

**Headless Services** are the interesting case
([Day 15](../../days/day-15-statefulsets-and-headless-services/)):

| Query | Returns |
|---|---|
| `web-headless.default.svc.cluster.local` | **one A record per ready endpoint** |
| `web-0.web-headless.default.svc.cluster.local` | that specific StatefulSet pod |

**A StatefulSet pod gets a stable, predictable name** — `<pod>.<service>.<ns>.svc`
— which is the entire reason StatefulSets require a headless Service. It is the
only way to address one replica out of many.

**SRV records** carry a port as well as a host:

```
_<port-name>._<protocol>.<service>.<namespace>.svc.cluster.local
```

```bash
dig SRV _http._tcp.web.default.svc.cluster.local
```

Named ports are the prerequisite — an unnamed port produces no SRV record.

### 24.2 CoreDNS is a Deployment

```bash
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get configmap coredns
```

Four objects, and the naming is a historical trap: **the Deployment is `coredns`
but the Service and the label are still `kube-dns`**, because CoreDNS replaced
kube-dns in 1.12 and the Service name could not change without breaking every
pod's `resolv.conf`.

```
   every pod's /etc/resolv.conf
        nameserver 10.96.0.10          <- the kube-dns SERVICE ClusterIP
             |
             |  DNAT by kube-proxy (CKA 23)
             v
   coredns pods (2 replicas, kube-system)
             |
             |  watch Services and EndpointSlices
             v
        the API server
```

**CoreDNS is a controller too** — it watches Services and EndpointSlices and
answers from an in-memory view. It does not query etcd and it stores nothing.

Note the dependency in that diagram: **pods reach DNS through a ClusterIP**, so
DNS depends on kube-proxy working. A cluster where kube-proxy is broken presents
as "DNS is down" ([CKA 23](../23-service-networking/)).

### 24.3 The Corefile

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

```
.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf { max_concurrent 1000 }
    cache 30
    loop
    reload
    loadbalance
}
```

**Each line is a plugin.** Order in the file does not determine execution order —
CoreDNS has a fixed chain order compiled in. What the file controls is which
plugins are enabled and how they are configured.

| Plugin | Does |
|---|---|
| `errors` | log errors |
| `health` | `:8080/health` for the liveness probe |
| `ready` | `:8181/ready` for the readiness probe |
| **`kubernetes`** | **the whole naming scheme from 24.1** |
| `prometheus` | metrics on `:9153` |
| **`forward`** | anything not matched goes upstream |
| `cache` | cache positive and negative answers |
| **`loop`** | **detect a forwarding loop and exit** |
| `reload` | re-read the Corefile without a restart |
| `loadbalance` | shuffle A records in the response |

Three deserve more:

**`kubernetes cluster.local`** sets the cluster domain. Everything under it is
answered from the API server's data; `pods insecure` controls the pod A records
from 24.1 — `disabled`, `insecure` (answer without checking the pod exists) or
`verified` (check first).

**`forward . /etc/resolv.conf`** is how a pod reaches `google.com`. CoreDNS reads
**the node's** `/etc/resolv.conf` and forwards anything it cannot answer there.
That is the boundary between cluster DNS and the outside world, and it is the one
line you change to point at a corporate resolver.

**`loop`** exists because of a specific, well-known failure: if the node's
`/etc/resolv.conf` points at `127.0.0.53` (systemd-resolved) and that forwards
back to CoreDNS, queries loop forever. The plugin detects it at startup and
**kills the pod deliberately** — a `CrashLoopBackOff` with `Loop ... detected` in
the logs is CoreDNS telling you the *node's* resolver configuration is wrong.

**`reload` means Corefile changes take effect without restarting anything.** Edit
the ConfigMap, wait about 30 seconds, done.

### 24.4 The kubelet writes `/etc/resolv.conf`

```bash
grep -E "clusterDNS|clusterDomain" /var/lib/kubelet/config.yaml
```

```yaml
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
```

**The kubelet, not CoreDNS, decides what a pod's resolver configuration says.** It
writes `nameserver`, the `search` list and `options ndots:5` into every pod at
creation. Change `clusterDNS` and existing pods keep the old value until they are
recreated.

### 24.5 `dnsPolicy`

```yaml
spec:
  dnsPolicy: ClusterFirst      # the default
```

| Policy | `/etc/resolv.conf` in the pod |
|---|---|
| **`ClusterFirst`** | cluster DNS, with the search list — **the default** |
| `Default` | **inherited from the node** — no cluster names resolve |
| `ClusterFirstWithHostNet` | cluster DNS **even though `hostNetwork: true`** |
| `None` | nothing — you supply it all via `dnsConfig` |

**The trap is `hostNetwork: true`.** A pod using the host's network namespace
gets `Default` unless you say otherwise, so **it silently cannot resolve any
Service**. If a host-networked pod cannot find `kubernetes.default`, this is why,
and the fix is one line:

```yaml
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

`dnsConfig` adds to or replaces the generated file:

```yaml
  dnsPolicy: None
  dnsConfig:
    nameservers: ["1.1.1.1"]
    searches: ["mycompany.internal"]
    options:
      - name: ndots
        value: "1"
```

**`ndots: 1` is the standard fix for DNS-heavy workloads** that mostly resolve
external names — it stops three failed cluster lookups preceding every one
([CKA 21](../21-linux-networking-foundations/)).

### 24.6 Reading a failure

| Symptom | Means |
|---|---|
| `NXDOMAIN` | the server answered: **that name does not exist**. DNS works |
| `SERVFAIL` | the server tried and failed — usually upstream forwarding |
| `connection timed out; no servers could be reached` | **nothing answered** — CoreDNS down, or kube-proxy not routing `10.96.0.10` |
| resolves by FQDN, not by short name | the **search list** is wrong |
| resolves from one pod, not another | different `dnsPolicy`, or `hostNetwork` |

**`NXDOMAIN` is good news.** It proves the whole path works — the pod reached
CoreDNS, CoreDNS consulted the API server's data, and the name genuinely is not
there. The bug is a typo or a missing Service, not infrastructure.

The first three commands for any DNS complaint:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns      # are they Running?
kubectl -n kube-system get endpoints kube-dns            # does the Service have them?
kubectl exec POD -- cat /etc/resolv.conf                 # is the pod asking the right server?
```

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka24
kubectl config set-context --current --namespace=cka24
kubectl apply -f solution/01-workload.yaml
kubectl apply -f solution/02-dnsutils.yaml
kubectl rollout status statefulset/web --timeout=180s
kubectl wait --for=condition=Ready pod/dnsutils --timeout=180s
```

> The lab uses `jessie-dnsutils` rather than busybox. **BusyBox's `nslookup`
> does not honour the search list**, so short names appear to fail on a cluster
> where they work perfectly — a false negative that has cost many people an
> afternoon.

### Step 1: Map the installation

```bash
bash solution/dns-map.sh
```

Nine sections. The ones to dwell on:

**1** — four objects, and the `coredns`/`kube-dns` naming split (24.2).

**5** — the `kubernetes` plugin line, which is the naming scheme from 24.1
expressed as configuration.

**6** — `forward . /etc/resolv.conf`, followed by the **node's** actual
`resolv.conf`. That is the boundary between cluster names and the internet, and
it is where a corporate resolver would go.

**7 and 8** — `clusterDNS` in the kubelet config must equal the `kube-dns`
Service ClusterIP. **If those two ever disagree, every pod created afterwards
has a broken resolver** and nothing else in the cluster complains.

### Step 2: Every form of name

```bash
D="kubectl exec dnsutils --"

$D cat /etc/resolv.conf
```

```
nameserver 10.96.0.10
search cka24.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

**A normal Service — one A record, four ways to ask:**

```bash
$D dig +short web
$D dig +short web.cka24
$D dig +short web.cka24.svc
$D dig +short web.cka24.svc.cluster.local
```

All four return the same ClusterIP. Only the last is a real name; the others are
the search list doing its work (24.1).

**Cross-namespace:**

```bash
$D dig +short kubernetes.default.svc.cluster.local
$D dig +short kube-dns.kube-system.svc.cluster.local
```

**Headless — the difference that matters:**

```bash
$D dig +short web.cka24.svc.cluster.local            # one address
$D dig +short web-headless.cka24.svc.cluster.local   # three addresses
```

```
10.96.201.44

10.244.1.7
10.244.2.9
10.244.1.8
```

**One record versus one per endpoint** (24.1). The first is a ClusterIP that
kube-proxy will DNAT; the second is the pod addresses themselves, with no
Service IP involved at all.

**A specific StatefulSet replica:**

```bash
$D dig +short web-0.web-headless.cka24.svc.cluster.local
$D dig +short web-1.web-headless.cka24.svc.cluster.local
kubectl get pods -o wide -l app=web
```

**Stable names, matched to stable pods.** This is why a StatefulSet requires a
headless Service and why `serviceName` is a mandatory field.

**SRV — host and port together:**

```bash
$D dig SRV +short _http._tcp.web.cka24.svc.cluster.local
$D dig SRV +short _http._tcp.web-headless.cka24.svc.cluster.local
```

```
0 100 80 web-0.web-headless.cka24.svc.cluster.local.
```

**Priority, weight, port, target.** The port came from the *named* port in the
Service — remove the name and this record disappears.

**Pod records, which are off by default:**

```bash
POD_IP=$(kubectl get pod web-0 -o jsonpath='{.status.podIP}')
DASHED=$(echo "$POD_IP" | tr '.' '-')
$D dig +short "${DASHED}.cka24.pod.cluster.local"
```

Whether that answers depends on the `pods` setting in the Corefile — check what
your cluster has:

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep pods
```

**Note it is under `.pod.` and not `.svc.`**, so no search suffix will ever find
it. You must write the FQDN.

**And a name that does not exist:**

```bash
$D dig nosuchservice.cka24.svc.cluster.local | grep -E "status:|ANSWER:"
```

```
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 12345
```

**`NXDOMAIN` is a working DNS system** (24.6). The path is fine; the name is not
there.

### Step 3: `dnsPolicy`

```bash
kubectl apply -f solution/03-dnspolicy-default.yaml
kubectl wait --for=condition=Ready pod/dns-default --timeout=120s

kubectl exec dnsutils    -- cat /etc/resolv.conf
kubectl exec dns-default -- cat /etc/resolv.conf
```

**Completely different files.** `dns-default` has the node's nameserver and no
cluster search list, so:

```bash
kubectl exec dns-default -- dig +short web.cka24.svc.cluster.local
kubectl exec dns-default -- dig +short web
```

Both fail. It can still reach the internet — it simply has no idea the cluster
exists (24.5).

Now the trap:

```bash
kubectl apply -f solution/04-hostnetwork-BAD.yaml
kubectl wait --for=condition=Ready pod/hostnet-broken --timeout=120s
kubectl get pod hostnet-broken -o jsonpath='{.spec.dnsPolicy}{"\n"}'
```

```
ClusterFirst
```

**The spec says `ClusterFirst` and it is not what happens.** With
`hostNetwork: true`, the kubelet applies the node's resolver anyway:

```bash
kubectl exec hostnet-broken -- cat /etc/resolv.conf
kubectl exec hostnet-broken -- dig +short kubernetes.default.svc.cluster.local
```

Nothing. **Nothing in `kubectl describe pod` hints at this** — the field reads
correctly and the behaviour is different. The fix:

```bash
kubectl apply -f solution/05-hostnetwork-fixed.yaml
kubectl wait --for=condition=Ready pod/hostnet-fixed --timeout=120s
kubectl exec hostnet-fixed -- cat /etc/resolv.conf
kubectl exec hostnet-fixed -- dig +short kubernetes.default.svc.cluster.local
```

**One line, `dnsPolicy: ClusterFirstWithHostNet`, and it works.** Remember this
one: it is a stock exam question and a real production incident.

### Step 4: `ndots`, measured

```bash
kubectl apply -f solution/06-dnsconfig-ndots.yaml
kubectl wait --for=condition=Ready pod/dns-ndots1 --timeout=120s

kubectl exec dnsutils   -- cat /etc/resolv.conf | grep options
kubectl exec dns-ndots1 -- cat /etc/resolv.conf | grep options
```

Count the queries each one makes for the same external name:

```bash
kubectl exec dnsutils   -- sh -c 'dig +search +trace=no api.github.com 2>/dev/null | grep -c "^api.github.com"'
kubectl exec dnsutils   -- host -v api.github.com 2>&1 | grep -c "Trying"
kubectl exec dns-ndots1 -- host -v api.github.com 2>&1 | grep -c "Trying"
```

```
4        <- ndots:5 -- three cluster suffixes tried first, then the real name
1        <- ndots:1
```

**Four DNS round trips instead of one, for every external name a pod resolves**
(24.5). At a few thousand requests per second, that is most of CoreDNS's load.

Cluster names still work in both:

```bash
kubectl exec dns-ndots1 -- dig +short web.cka24.svc.cluster.local
kubectl exec dns-ndots1 -- dig +short web            # short name -- now fails
```

**The trade is explicit:** `ndots: 1` makes external names cheap and **breaks
short cluster names**, because a bare `web` is no longer expanded. Applications
must use the FQDN. That is why it is a per-workload `dnsConfig` and not a cluster
default.

### Step 5: Edit the Corefile

Add a fake internal name, the way you would point a cluster at a private zone:

```bash
bash solution/corefile-edit.sh show
bash solution/corefile-edit.sh add
```

It inserts:

```
    hosts {
       10.9.9.9 internal.example
       fallthrough
    }
```

**`fallthrough` is the important word.** Without it, the `hosts` plugin answers
*every* query it has no record for with `NXDOMAIN`, and the `kubernetes` plugin
below it never runs. Adding a `hosts` block without `fallthrough` takes cluster
DNS down completely, and it is a genuinely common mistake.

Wait for the reload, then test:

```bash
sleep 35
kubectl exec dnsutils -- dig +short internal.example
kubectl exec dnsutils -- dig +short web.cka24.svc.cluster.local
```

```
10.9.9.9
10.96.201.44
```

**Both work — the new record, and everything that was already there.** And
nothing was restarted:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5 | grep -i reload
```

`AGE` is unchanged and the log says it reloaded. **That is the `reload` plugin**
(24.3), and it is why CoreDNS configuration changes are safe to make during the
day.

```bash
bash solution/corefile-edit.sh remove
sleep 35
kubectl exec dnsutils -- dig +short internal.example       # nothing again
```

### Step 6: Take DNS away

```bash
kubectl -n kube-system scale deployment coredns --replicas=0
kubectl -n kube-system get endpoints kube-dns
```

```
NAME       ENDPOINTS   AGE
kube-dns   <none>      3h
```

Now, from a pod:

```bash
kubectl exec dnsutils -- dig +time=3 +tries=1 web.cka24.svc.cluster.local 2>&1 | tail -3
```

```
;; communications error to 10.96.0.10#53: connection refused
```

**Connection refused, not a timeout** — and you know why from
[CKA 23](../23-service-networking/): a Service with no endpoints gets a `REJECT`
rule, so the failure is instant. **The failure mode of DNS tells you which layer
broke:**

| What you see | Where it broke |
|---|---|
| `connection refused` | the Service has **no endpoints** -- CoreDNS is not running |
| `connection timed out` | endpoints exist but nothing answers -- **kube-proxy**, or a NetworkPolicy |
| `NXDOMAIN` | **everything works**; the name is wrong |

Confirm the first row directly:

```bash
docker exec devops-worker sh -c 'iptables -t nat -S KUBE-SERVICES | grep 10.96.0.10'
```

And note what did **not** break:

```bash
kubectl get pods -A | head -5
kubectl exec dnsutils -- ping -c1 -W2 $(kubectl get pod web-0 -o jsonpath='{.status.podIP}')
```

**Pod-to-pod networking is untouched.** DNS is one Deployment, not part of the
network — a distinction that decides where you look next.

```bash
kubectl -n kube-system scale deployment coredns --replicas=2
kubectl -n kube-system rollout status deployment/coredns --timeout=120s
kubectl exec dnsutils -- dig +short web.cka24.svc.cluster.local
```

### Step 7: Follow an external query

```bash
kubectl exec dnsutils -- dig example.com | grep -E "SERVER:|status:"
```

**Answered by `10.96.0.10` — CoreDNS — which forwarded it to the node's
resolver** and passed the answer back (24.3):

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -A2 forward
docker exec devops-control-plane cat /etc/resolv.conf
```

**Every external lookup your workloads make goes through those two CoreDNS
pods**, which is worth remembering when sizing them.

### Cleanup

```bash
bash solution/corefile-edit.sh remove 2>/dev/null
kubectl delete namespace cka24 --ignore-not-found
kubectl -n kube-system get deployment coredns          # confirm replicas are back
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Write the names

Given a Service `payments` with a named port `grpc` in namespace `fin`, backed by
a StatefulSet `payments` of 3 replicas behind a headless Service
`payments-headless`, write:

1. The FQDN of the Service.
2. What a pod in `fin` can use as a short name, and what a pod in `default` must
   use.
3. The name that returns all three pod addresses.
4. The name of the second replica specifically.
5. The SRV query that returns the gRPC port.
6. The record for a pod at `10.244.3.17`, and why you probably cannot use it.

### C2 - Five DNS failures

For each, name the cause and the confirming command:

1. `dig` to a Service FQDN returns `connection refused`, instantly.
2. The same query times out after 5 seconds.
3. `web.cka24.svc.cluster.local` resolves; `web` does not.
4. Resolution works from every pod except one, which uses `hostNetwork`.
5. CoreDNS pods are in `CrashLoopBackOff` with `Loop ... detected` in the logs.

### C3 - Point at a corporate resolver

All `*.corp.internal` names must resolve through `10.50.0.53`; everything else
should behave as it does now.

1. Write the Corefile change.
2. Explain why you would not simply change `forward . /etc/resolv.conf`.
3. How do you apply it, and how long until it takes effect?
4. What is the rollback, and how would you know you needed one?

### C4 - The `fallthrough` trap

A colleague adds this to the Corefile and the entire cluster loses DNS:

```
    hosts {
       10.9.9.9 internal.example
    }
```

Explain exactly what happens to a query for
`kubernetes.default.svc.cluster.local` after this change, why the `hosts` plugin
is consulted at all for a name it has never heard of, and give both the fix and
the fastest way to recover a cluster already in this state.

### C5 - Scale CoreDNS

A 200-node cluster reports intermittent DNS timeouts under load.

1. Give four things you would measure, and the command for each.
2. Name three independent changes that reduce DNS load, with the trade-off of
   each.
3. Why is "add more CoreDNS replicas" often not the fix, and when is it?

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the four CoreDNS objects exist and `clusterDNS` matches the `kube-dns`
ClusterIP; a Service resolves by all four name forms; a headless Service returns
one record per endpoint; StatefulSet pod names resolve individually; an SRV
record carries the named port; a non-existent name returns NXDOMAIN rather than
a timeout; and a `hostNetwork` pod without `ClusterFirstWithHostNet` cannot
resolve Services while the fixed one can.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the three commands for any DNS complaint
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get endpoints kube-dns
kubectl exec POD -- cat /etc/resolv.conf

# the configuration
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
kubectl -n kube-system edit cm coredns          # reload applies it in ~30s

# what the kubelet stamps into pods
grep -A3 clusterDNS /var/lib/kubelet/config.yaml

# a disposable debugging pod
kubectl run dnsutils --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- bash

# every form of query
dig +short web.default.svc.cluster.local
dig +short web-headless.default.svc.cluster.local     # N records
dig +short web-0.web-headless.default.svc.cluster.local
dig SRV +short _http._tcp.web.default.svc.cluster.local
dig +search web
nslookup web.default.svc.cluster.local
```

**Traps**

- **The Deployment is `coredns`; the Service and label are `kube-dns`.**
- **`hostNetwork: true` silently disables cluster DNS.** Use
  `dnsPolicy: ClusterFirstWithHostNet`.
- **`NXDOMAIN` means DNS works.** Look at the name, not the cluster.
- **`connection refused` = no endpoints; a timeout = something else.**
- **Pod records live under `.pod.`, not `.svc.`**, are off by default, and are
  named after the IP.
- **SRV records need a *named* port.**
- **A headless Service returns N records** and has no ClusterIP.
- **`ndots:5` costs three failed lookups per external name**; `ndots:1` fixes
  that and breaks short cluster names.
- **`hosts` and similar plugins need `fallthrough`**, or they answer NXDOMAIN
  for everything they do not know.
- **`reload` means no restart is needed** after a Corefile edit — and it also
  means a broken Corefile takes effect on its own.
- **DNS depends on kube-proxy**, because `10.96.0.10` is a ClusterIP.
- **BusyBox `nslookup` ignores the search list.** Use `dnsutils`, or an FQDN.

---

**Previous:** [CKA 23 — Service Networking](../23-service-networking/)
**Next:** [CKA 25 — Ingress and Gateway API in Depth](../25-ingress-gateway-in-depth/)
