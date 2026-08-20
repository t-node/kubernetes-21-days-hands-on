# Day 06 — Services I: ClusterIP & Cluster DNS

**Time:** 75-90 minutes
**Prerequisites:** Days 04-05

Pods die and get new IPs. Something has to give them a stable address. That
something is a Service, and today you learn the type that does 90% of the work:
`ClusterIP`.

---

## Part 1 - Concepts

### 6.1 The problem, precisely

```bash
kubectl get pods -n devboard -o wide
```

Every pod has an IP like `10.244.1.7`. Now delete a pod: the replacement has a
different IP. Scale to 5: three new IPs appear. Reschedule to another node: new
IP again.

So how does the frontend reach the backend?

- Hardcode a pod IP → breaks the first time that pod restarts.
- Query the API for pod IPs → now every app needs Kubernetes credentials and
  retry logic. No.

**A Service is a stable virtual IP and DNS name in front of a changing set of
pods.**

```
              Service: devboard-backend
              ClusterIP: 10.96.43.17   (never changes)
              DNS: devboard-backend.devboard.svc.cluster.local
                            |
              selector: app=devboard-backend
                 /          |          \
          [pod .1.7]   [pod .2.3]   [pod .1.9]
                (these come and go freely)
```

### 6.2 How a Service actually works (three moving parts)

1. **The Service object** holds a selector and a virtual IP (the ClusterIP).
   That IP is allocated from the service CIDR and is not assigned to any network
   interface anywhere — it is purely a rule target.

2. **The EndpointSlice controller** watches pods matching the selector, filters
   to those that are **Ready**, and writes their IPs and ports into
   EndpointSlice objects.

3. **kube-proxy** on every node watches EndpointSlices and programs iptables (or
   IPVS) rules: "traffic to `10.96.43.17:8080` → DNAT to one of these pod IPs,
   picked at random".

The consequences worth internalising:

- Load balancing is **L4** (per connection), not L7 (per request). A long-lived
  HTTP/2 or gRPC connection sticks to one pod. This surprises people.
- There is no proxy process in the path. Packets are rewritten in the kernel.
- **A pod that is not Ready is removed from the EndpointSlice** — which is
  precisely how readiness probes (Day 13) take a pod out of rotation without
  killing it.

### 6.3 The three ports, and the confusion they cause

```yaml
spec:
  ports:
    - port: 8080         # the SERVICE's port. Clients connect here.
      targetPort: 5000   # the CONTAINER's port. Where traffic is forwarded.
      protocol: TCP
      name: http
```

```
client ──▶ devboard-backend:8080 ──▶ pod:5000
              (port)                  (targetPort)
```

- **`port`** — what the Service listens on. You choose it. Clients use it.
- **`targetPort`** — what the container listens on. The app decides it.
- If you omit `targetPort`, it defaults to the same value as `port`. Convenient,
  and the source of a lot of confusion when they should differ.
- `targetPort` may be a **name** rather than a number, referring to a
  `containerPort` name in the pod spec. That is the more robust form:

```yaml
# in the pod template
ports:
  - containerPort: 5000
    name: http

# in the Service
targetPort: http     # resolves per-pod; different pods could even differ
```

A third port, **`nodePort`**, appears only for `type: NodePort` — that is
tomorrow.

### 6.4 The four Service types (today: the first one)

| Type | Reachable from | Use |
|---|---|---|
| **ClusterIP** (default) | inside the cluster only | internal service-to-service — most Services |
| **NodePort** | `<any-node-ip>:30000-32767` | Day 07 |
| **LoadBalancer** | an external cloud LB | Day 07 |
| **ExternalName** | CNAME to an external DNS name | Day 07 |

Plus **headless** (`clusterIP: None`), which is not a type but a mode: no
virtual IP, DNS returns pod IPs directly. Day 15 uses it for StatefulSets.

### 6.5 Cluster DNS: the part that feels like magic

CoreDNS runs in `kube-system` and watches Services. For every Service it creates
an A record:

```
<service>.<namespace>.svc.cluster.local  →  the ClusterIP
```

Every pod gets a `/etc/resolv.conf` like this:

```
nameserver 10.96.0.10                      # the kube-dns Service ClusterIP
search devboard.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

The **search** list is why short names work. Inside a pod in `devboard`:

| You write | Resolves via | Works from |
|---|---|---|
| `devboard-backend` | search path appends `devboard.svc.cluster.local` | same namespace only |
| `devboard-backend.devboard` | search path appends `svc.cluster.local` | anywhere in the cluster |
| `devboard-backend.devboard.svc.cluster.local` | exact, fully qualified | anywhere |

That is why the frontend's nginx config can simply say
`proxy_pass http://devboard-backend:8080;` and it just works.

**`ndots:5` is worth knowing about.** It means "if the name has fewer than 5
dots, try the search domains first". So looking up `api.github.com` (2 dots)
generates four failed cluster lookups before the real one. On a high-traffic
service this shows up as DNS latency; the fix is a trailing dot
(`api.github.com.`) or tuning `dnsConfig`.

---

## Part 2 - Hands-on lab

### Step 1: Show the problem first

```bash
kubectl apply -f solution/backend-deployment.yaml
kubectl get pods -n devboard -l app=demo-backend -o wide
```

Note a pod IP. Then:

```bash
kubectl delete pod -n devboard -l app=demo-backend --wait=false
sleep 10
kubectl get pods -n devboard -l app=demo-backend -o wide
```

Every IP changed. Any client that had cached one is now broken.

### Step 2: Create a ClusterIP Service

Create `backend-service.yaml`:

```yaml
apiVersion: v1                 # Service is core/v1, NOT apps/v1
kind: Service
metadata:
  name: demo-backend
  namespace: devboard
  labels:
    app: demo-backend
spec:
  type: ClusterIP              # the default; written out for clarity
  selector:
    app: demo-backend          # <- must match the POD labels, not the Deployment's
  ports:
    - name: http
      port: 8080               # clients connect here
      targetPort: 80           # the container listens here
      protocol: TCP
```

```bash
kubectl apply -f backend-service.yaml
kubectl get svc -n devboard
```

```
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
demo-backend   ClusterIP   10.96.147.203   <none>        8080/TCP   5s
```

`EXTERNAL-IP: <none>` is correct and expected for ClusterIP.

### Step 3: Look at the endpoints — this is the debugging skill

```bash
kubectl get endpoints demo-backend -n devboard
kubectl get endpointslices -n devboard -l kubernetes.io/service-name=demo-backend
kubectl describe endpointslice -n devboard -l kubernetes.io/service-name=demo-backend
```

```
NAME           ENDPOINTS                                      AGE
demo-backend   10.244.1.12:80,10.244.2.8:80,10.244.1.13:80    30s
```

Three pod IPs. Compare with `kubectl get pods -o wide` — they are exactly your
pod IPs.

> **Memorise this:** when a Service "does not work", the very first command is
> `kubectl get endpoints <svc>`. If `ENDPOINTS` is `<none>`, the problem is
> **always** on the Service→Pod side: the selector does not match any pod labels,
> or the pods exist but are not Ready. If endpoints are populated, the problem is
> elsewhere — ports, network policy, or the client.

`Endpoints` is the legacy object and `EndpointSlice` is its scalable successor
(a Service with 5000 pods gets many slices instead of one enormous object).
`kubectl get endpoints` still works and is quicker to type.

### Step 4: Prove it from inside the cluster

A ClusterIP is not reachable from your laptop. You need a pod. Spin up a
disposable one:

```bash
kubectl run netshoot --rm -it -n devboard \
  --image=nicolaka/netshoot:latest -- bash
```

(If pulling that image is slow, `--image=busybox:1.36 -- sh` works for most of
it; busybox has `wget` and `nslookup` but not `dig` or `curl`.)

Inside:

```sh
# 1. DNS, short name (same namespace)
nslookup demo-backend

# 2. DNS, fully qualified
nslookup demo-backend.devboard.svc.cluster.local

# 3. hit the Service
curl -s demo-backend:8080 | head -5

# 4. hit it 10 times and watch requests spread across pods
for i in $(seq 1 10); do curl -s demo-backend:8080 | grep -o 'nginx' ; done

# 5. the resolv.conf that makes short names work
cat /etc/resolv.conf

# 6. cross-namespace lookup: this FAILS
nslookup demo-backend.default

# 7. a kube-system Service, fully qualified: this works
nslookup kube-dns.kube-system.svc.cluster.local

exit
```

Step 6 failing and step 7 working is the whole namespace/DNS lesson in two
commands.

### Step 5: Show that a Service survives pod churn

Terminal 1 — a client loop from inside the cluster:

```bash
kubectl run poller --rm -it -n devboard --image=busybox:1.36 -- \
  sh -c 'while true; do wget -qO- --timeout=2 demo-backend:8080 >/dev/null && echo "$(date +%T) OK" || echo "$(date +%T) FAIL"; sleep 1; done'
```

Terminal 2 — churn the pods underneath it:

```bash
kubectl delete pod -n devboard -l app=demo-backend --wait=false
kubectl scale deployment demo-backend --replicas=6 -n devboard
kubectl scale deployment demo-backend --replicas=2 -n devboard
```

Terminal 1 keeps printing OK (you may catch one or two FAILs during the full
delete — that is the readiness-probe gap Day 13 closes). The client never
learned a single pod IP. That is the Service doing its job.

### Step 6: Environment variables (the older mechanism)

Before DNS, Kubernetes injected Service addresses as environment variables. It
still does:

```bash
kubectl run envtest --rm -it -n devboard --image=busybox:1.36 -- \
  sh -c 'env | grep -i demo_backend'
```

```
DEMO_BACKEND_SERVICE_HOST=10.96.147.203
DEMO_BACKEND_SERVICE_PORT=8080
DEMO_BACKEND_PORT_8080_TCP_ADDR=10.96.147.203
```

**Do not rely on these.** They are only injected for Services that existed
*before* the pod started — a fatal ordering dependency. Use DNS. This is a good
interview answer to "how does service discovery work in Kubernetes": DNS is the
mechanism; env vars are the legacy fallback with an ordering problem.

### Step 7: Named ports (the robust form)

Change the Service to reference the port by name instead of number:

```yaml
# pod template
ports:
  - containerPort: 80
    name: http

# Service
ports:
  - port: 8080
    targetPort: http     # <- the NAME, not 80
```

```bash
kubectl apply -f solution/backend-service-namedport.yaml
kubectl get endpoints demo-backend -n devboard      # still populated
```

Now the container can move to a different port and only the Deployment changes.
Use named ports in real manifests.

### Step 8: A headless Service (preview of Day 15)

```yaml
spec:
  clusterIP: None      # <- headless
  selector:
    app: demo-backend
  ports:
    - port: 8080
```

```bash
kubectl apply -f solution/backend-service-headless.yaml
kubectl get svc demo-backend-headless -n devboard     # CLUSTER-IP: None

kubectl run dnstest --rm -it -n devboard --image=busybox:1.36 -- \
  nslookup demo-backend-headless
```

DNS now returns **all pod IPs** instead of one virtual IP. There is no load
balancing and no NAT — the client sees the real backends and decides for itself.
That is what a StatefulSet needs so you can address `postgres-0` specifically.

### Step 9: A Service with no selector (pointing at something external)

Occasionally you want a stable in-cluster name for a database that lives outside
the cluster. Omit the selector and write the endpoints by hand:

```bash
kubectl apply -f solution/external-db-service.yaml
kubectl get endpointslices -n devboard -l kubernetes.io/service-name=external-db
```

Now `external-db:5432` inside the cluster reaches whatever IP you wrote. Useful
during a migration: applications keep using a Kubernetes name while the actual
backend moves from outside to inside the cluster.

---

## Validate

```bash
kubectl apply -f solution/backend-deployment.yaml
kubectl apply -f solution/backend-service.yaml
kubectl rollout status deployment/demo-backend -n devboard

# 1. the Service has a ClusterIP
kubectl get svc demo-backend -n devboard -o jsonpath='{.spec.clusterIP}{"\n"}'

# 2. endpoints are populated (this is the important one)
kubectl get endpoints demo-backend -n devboard

# 3. DNS resolves and the service answers from inside the cluster
kubectl run check --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  sh -c 'nslookup demo-backend >/dev/null && wget -qO- demo-backend:8080 | head -1'
```

Ready for Day 07 when you can:

1. Explain `port` vs `targetPort` without hesitating.
2. Say what `kubectl get endpoints` tells you and why it is the first command.
3. Give the three DNS forms and say which works across namespaces.
4. Explain why a long-lived gRPC connection is not load balanced by a Service.

---

## Break it (these are the four real Service failures)

**A. Selector typo — the number one Service bug.**

```bash
kubectl patch svc demo-backend -n devboard \
  -p '{"spec":{"selector":{"app":"demo-backendd"}}}'

kubectl get endpoints demo-backend -n devboard
# ENDPOINTS: <none>       <- there it is

kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 demo-backend:8080
# wget: download timed out
```

DNS resolves fine, the ClusterIP exists, and the connection hangs — because
there is nothing behind it. Fix:

```bash
kubectl patch svc demo-backend -n devboard \
  -p '{"spec":{"selector":{"app":"demo-backend"}}}'
```

**B. Wrong targetPort.**

```bash
kubectl patch svc demo-backend -n devboard \
  -p '{"spec":{"ports":[{"name":"http","port":8080,"targetPort":9999}]}}'

kubectl get endpoints demo-backend -n devboard      # 10.244.1.12:9999 ...
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 demo-backend:8080
# connection refused
```

Note the crucial difference from case A: **endpoints ARE populated** — just
pointing at a port nothing listens on. `<none>` means selector; `connection
refused` on populated endpoints means port. Restore with
`kubectl apply -f solution/backend-service.yaml`.

**C. Pods not Ready are excluded.**

```bash
kubectl patch deployment demo-backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","readinessProbe":{"httpGet":{"path":"/nope","port":80},"periodSeconds":2}}]}}}}'

kubectl get pods -n devboard -l app=demo-backend    # READY 0/1
kubectl get endpoints demo-backend -n devboard      # <none>
```

The pods are *running* and healthy-ish, but not Ready, so the endpoints
controller removed them. This is the mechanism behind zero-downtime deploys and
also a very common self-inflicted outage: a probe pointing at a path that does
not exist takes your whole service offline while every pod looks "Running".

```bash
kubectl apply -f solution/backend-deployment.yaml
```

**D. Cross-namespace short name.**

```bash
kubectl run t --rm -i -n default --image=busybox:1.36 --restart=Never -- \
  nslookup demo-backend
# ** server can't find demo-backend: NXDOMAIN

kubectl run t --rm -i -n default --image=busybox:1.36 --restart=Never -- \
  nslookup demo-backend.devboard.svc.cluster.local
# works
```

---

## The Service debugging flowchart (screenshot this)

```
"my service does not work"
        |
        v
kubectl get endpoints <svc> -n <ns>
        |
   +----+--------------------------+
   |                               |
ENDPOINTS: <none>            ENDPOINTS: 10.244.x.y:port
   |                               |
   v                               v
Service -> Pod problem        Pod -> App problem
   |                               |
   +- selector does not match      +- wrong targetPort (connection refused)
   |  pod labels?                  +- app not listening on 0.0.0.0?
   |  kubectl get pods --show-labels|  (binding to 127.0.0.1 inside a container
   |                               |   is invisible from outside the pod)
   +- pods not Ready?              +- NetworkPolicy blocking it?
   |  kubectl get pods             +- client using the wrong namespace/name?
   |                               +- app returning 5xx? check kubectl logs
   +- wrong namespace?
```

---

## Interview questions

<details>
<summary><b>1. What is a Service and why do you need one?</b></summary>

A stable virtual IP and DNS name in front of a dynamic set of pods, selected by
labels. Pods are ephemeral and get new IPs on every restart or reschedule, so
nothing can address them directly. The Service also load balances across the
Ready pods.
</details>

<details>
<summary><b>2. How does a Service actually route traffic?</b></summary>

The endpoints controller watches pods matching the selector, keeps the Ready
ones in EndpointSlices, and kube-proxy on every node programs iptables or IPVS
rules that DNAT traffic destined for the ClusterIP to a randomly chosen pod IP.
There is no userspace proxy in the data path in the default mode; the ClusterIP
is a rule target, not an address on any interface.
</details>

<details>
<summary><b>3. port vs targetPort vs nodePort?</b></summary>

`port` is what the Service listens on and clients connect to. `targetPort` is
the container port traffic is forwarded to, and may be a named port.
`nodePort` (NodePort/LoadBalancer only) is the port opened on every node in the
30000-32767 range. `targetPort` defaults to `port` if omitted.
</details>

<details>
<summary><b>4. A Service returns nothing. How do you debug it?</b></summary>

`kubectl get endpoints <svc>` first. If it is `<none>`, the Service selector
does not match any pod labels or no pod is Ready — compare
`kubectl get pods --show-labels` with the Service selector. If endpoints are
populated, the problem is downstream: wrong targetPort (connection refused), the
app bound to 127.0.0.1 instead of 0.0.0.0, a NetworkPolicy, or the app itself
erroring. Test from inside the cluster with a debug pod, not from your laptop.
</details>

<details>
<summary><b>5. How does DNS work in a cluster?</b></summary>

CoreDNS runs as a Deployment in kube-system and is itself fronted by the
`kube-dns` Service. Every pod's `/etc/resolv.conf` points at that ClusterIP with
a search path of `<ns>.svc.cluster.local svc.cluster.local cluster.local`. A
Service gets an A record at `<svc>.<ns>.svc.cluster.local`, so a short name works
within the namespace and a qualified name works anywhere.
</details>

<details>
<summary><b>6. Does a Service load balance HTTP requests?</b></summary>

No — it load balances *connections*, at L4. Each new TCP connection is DNATed to
a random pod, but every request on that connection goes to the same pod. With
HTTP/1.1 keep-alive, gRPC or HTTP/2, one client can pin to one pod indefinitely
and the load becomes badly skewed. Fixing it needs L7 load balancing: an ingress
controller, a service mesh, or client-side balancing over a headless Service.
</details>

<details>
<summary><b>7. What is a headless Service?</b></summary>

A Service with `clusterIP: None`. No virtual IP is allocated and kube-proxy
programs nothing; DNS returns the A records of the individual pods instead. It
is used when the client needs to address specific pods — StatefulSets, where
`postgres-0.postgres.devboard.svc.cluster.local` resolves to one particular
replica — or when doing client-side load balancing.
</details>

<details>
<summary><b>8. Can a Service point to something outside the cluster?</b></summary>

Yes, two ways. Create a Service with no selector and hand-write an EndpointSlice
containing the external IPs — the ClusterIP and DNS name work normally. Or use
`type: ExternalName`, which creates a CNAME to an external DNS name with no
proxying at all. The first is useful for migrating a database into the cluster
without changing application config.
</details>

<details>
<summary><b>9. Endpoints vs EndpointSlice?</b></summary>

Endpoints is the original object holding every backend for a Service in one
resource, which becomes a scaling problem at thousands of pods — any change
rewrites the whole object and pushes it to every node. EndpointSlice splits them
into chunks of 100 by default, so updates are incremental. EndpointSlice is the
default since 1.21; Endpoints is still maintained for compatibility.
</details>

<details>
<summary><b>10. What does ndots:5 do and when does it bite?</b></summary>

It tells the resolver to try the search domains first for any name with fewer
than five dots. Looking up `api.stripe.com` therefore produces several failed
cluster-DNS queries before the correct one, multiplying DNS load and latency on
busy services. Mitigations: a trailing dot to force absolute resolution, a
per-pod `dnsConfig` with a lower ndots, or NodeLocal DNSCache.
</details>

---

## Cheat card

```bash
kubectl get svc -n devboard
kubectl get svc demo-backend -n devboard -o yaml
kubectl describe svc demo-backend -n devboard

# THE debugging command
kubectl get endpoints demo-backend -n devboard
kubectl get endpointslices -n devboard

# test from inside the cluster (never from your laptop for a ClusterIP)
kubectl run t --rm -it -n devboard --image=nicolaka/netshoot -- bash
kubectl run t --rm -i  -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- demo-backend:8080

# generate a Service for an existing Deployment
kubectl expose deployment demo-backend --port=8080 --target-port=80 \
  -n devboard --dry-run=client -o yaml
```

| DNS form | Resolves from |
|---|---|
| `svc` | the same namespace |
| `svc.namespace` | anywhere |
| `svc.namespace.svc.cluster.local` | anywhere (fully qualified) |
| `pod-0.svc.namespace.svc.cluster.local` | headless Service pods (Day 15) |

---

**Next: [Day 07 - NodePort, LoadBalancer and ExternalName](../day-07-services-nodeport-loadbalancer/)**
