# Day 07 — Services II: NodePort, LoadBalancer & ExternalName

**Time:** 60-75 minutes
**Prerequisites:** Day 06

Yesterday's ClusterIP is invisible from outside the cluster. Today you get
traffic in from your browser — and understand exactly why `type: LoadBalancer`
hangs forever on a local cluster.

---

## Part 1 - Concepts

### 7.1 The ladder of Service types

Each type **builds on** the one before it. This is the mental model that makes
them stick:

```
ExternalName   CNAME to an outside DNS name. No proxying at all.

LoadBalancer   = NodePort + a cloud load balancer in front of the nodes
                 ^ needs a cloud-controller-manager

NodePort       = ClusterIP + a port opened on EVERY node
                 ^ 30000-32767

ClusterIP      a virtual IP reachable only inside the cluster
```

Create a `type: LoadBalancer` Service and you get a ClusterIP **and** a NodePort
**and** a cloud LB. Look at `kubectl get svc` output on a cloud cluster and you
will see all three.

### 7.2 NodePort

```yaml
spec:
  type: NodePort
  ports:
    - port: 8080          # the ClusterIP port (still exists)
      targetPort: 80      # the container port
      nodePort: 30080     # the port opened on every node. 30000-32767.
```

```
your laptop
     |
     v
<any node IP>:30080          <- open on EVERY node, even nodes with no pods
     |
     v  kube-proxy DNATs
Service ClusterIP:8080
     |
     v
pod:80
```

Key facts, each of which is an interview question:

- The port is open on **every node**, not just nodes running the pod. Hit a node
  with no pods and kube-proxy forwards you to a node that has one.
- The range is **30000-32767** by default (`--service-node-port-range`). Ask for
  80 and you are refused.
- Omit `nodePort` and Kubernetes allocates a free one. Specify it and you own it
  cluster-wide — two Services cannot share a nodePort.
- **`externalTrafficPolicy`** changes the behaviour meaningfully:
  - `Cluster` (default): any node accepts and may forward to another node. Even
    load spread, but the **source IP is lost** to SNAT.
  - `Local`: a node only serves pods it hosts locally. **Source IP preserved**,
    no extra hop, but a node with no pods refuses the connection — which is
    actually how cloud LB health checks find the right nodes.

**Why NodePort is not how you expose production traffic:** ugly high ports,
clients must know node IPs, no TLS termination, no host or path routing, and
nothing in front if a node dies. It is right for dev, for on-prem behind your
own load balancer, and for learning. Day 20 (Ingress) is the production answer.

### 7.3 LoadBalancer

```yaml
spec:
  type: LoadBalancer
```

On EKS/GKE/AKS the cloud-controller-manager sees this, calls the cloud API,
provisions a real load balancer pointing at your nodes' NodePorts, and writes
the public address back into `status.loadBalancer.ingress`. `EXTERNAL-IP` fills
in after a minute or two.

**On kind, `EXTERNAL-IP` stays `<pending>` forever.** There is no
cloud-controller-manager to act on it. This is not a bug and you should be able
to explain it — the object is valid, nothing is watching for it.

Workarounds for local clusters: **MetalLB** (a bare-metal LB implementation) or
`cloud-provider-kind`. Both are out of scope here; on kind we use NodePort plus
`extraPortMappings`.

The other objection to LoadBalancer: **one cloud LB per Service**, each costing
real money. Twenty microservices means twenty load balancers. The standard fix
is one LoadBalancer Service in front of an **ingress controller**, which then
routes to many ClusterIP Services by host and path. That is Day 20.

### 7.4 ExternalName

```yaml
spec:
  type: ExternalName
  externalName: db.prod.example.com
```

No ClusterIP, no endpoints, no proxying. CoreDNS just returns a **CNAME**. It is
purely a DNS alias, so your app can talk to `payments-api` in-cluster while it
actually resolves to a vendor's hostname. Caveats: it only works for DNS-based
clients, TLS SNI and Host headers still carry the *external* name, and there is
no port remapping.

### 7.5 kind's extra wrinkle: extraPortMappings

Your nodes are Docker containers. A NodePort is opened on the *node*, which is
inside Docker's network. Your browser is not.

That is what these lines in `cluster/kind-config.yaml` are for:

```yaml
extraPortMappings:
  - containerPort: 30080     # the nodePort, inside the node container
    hostPort: 30080          # the port on your laptop
```

`localhost:30080` → node container port 30080 → NodePort → Service → pod.

**This is the single most common kind confusion.** If you create a NodePort of
32100 and it does not work from your browser, it is because there is no host
mapping for 32100. Use 30080 or 30081 (already mapped), or add a mapping and
recreate the cluster.

---

## Part 2 - Hands-on lab

### Step 1: A NodePort you can actually open in a browser

```bash
kubectl apply -f solution/frontend-deployment.yaml
kubectl apply -f solution/frontend-service-nodeport.yaml
kubectl get svc -n devboard
```

```
NAME                TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)
devboard-frontend   NodePort   10.96.201.44    <none>        80:30080/TCP
```

Read `80:30080/TCP` as `port:nodePort`. Now open <http://localhost:30080> — the
nginx welcome page, served from a pod, through a Service, through a NodePort,
through a Docker port mapping.

Also confirm the ClusterIP still exists (NodePort is a superset):

```bash
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- devboard-frontend:80 | head -3
```

### Step 2: Prove the port is open on every node

```bash
kubectl get pods -n devboard -l app=devboard-frontend -o wide
```

Note which nodes the pods are on. Now reach the app through a node that has
**no** pod on it:

```bash
# get every node's internal IP
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

# from inside the cluster, hit each node IP on the nodePort
kubectl run t --rm -it -n devboard --image=busybox:1.36 -- sh
# inside:
#   wget -qO- 172.18.0.2:30080 | head -2
#   wget -qO- 172.18.0.3:30080 | head -2
#   wget -qO- 172.18.0.4:30080 | head -2
#   exit
```

All three answer, including nodes with no frontend pod. kube-proxy forwarded
across nodes for you. That is `externalTrafficPolicy: Cluster`.

### Step 3: externalTrafficPolicy: Local, and the trade-off

```bash
kubectl patch svc devboard-frontend -n devboard \
  -p '{"spec":{"externalTrafficPolicy":"Local"}}'

kubectl scale deployment devboard-frontend --replicas=1 -n devboard
kubectl get pods -n devboard -o wide       # note the ONE node hosting it
```

Repeat the per-node test from Step 2. Now only the node actually hosting the pod
answers; the others refuse the connection.

| | `Cluster` (default) | `Local` |
|---|---|---|
| Node without pods | forwards to another node | refuses |
| Extra network hop | yes | no |
| Client source IP | lost (SNAT) | preserved |
| Load spread | even | depends on pod placement |

Preserving the source IP matters for rate limiting, geo-IP, audit logs and
allow-lists. Restore:

```bash
kubectl patch svc devboard-frontend -n devboard \
  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
kubectl scale deployment devboard-frontend --replicas=3 -n devboard
```

### Step 4: LoadBalancer, and why it hangs here

```bash
kubectl apply -f solution/frontend-service-loadbalancer.yaml
kubectl get svc devboard-frontend-lb -n devboard -w      # Ctrl-C after 30s
```

```
NAME                   TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
devboard-frontend-lb   LoadBalancer   10.96.88.31    <pending>     80:31677/TCP
```

`<pending>` forever. Explain it to yourself out loud: the Service object is
perfectly valid and Kubernetes did its part — it allocated a ClusterIP *and* a
nodePort (31677 above). What is missing is a cloud-controller-manager to see
`type: LoadBalancer` and go provision an actual load balancer.

Confirm the NodePort part really was created and works:

```bash
kubectl get svc devboard-frontend-lb -n devboard \
  -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
```

On EKS the same manifest would produce an ELB DNS name in `EXTERNAL-IP` within
about two minutes, and annotations control the details:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
```

```bash
kubectl delete -f solution/frontend-service-loadbalancer.yaml
```

### Step 5: ExternalName

```bash
kubectl apply -f solution/external-name-service.yaml
kubectl get svc external-api -n devboard
```

```
NAME           TYPE           CLUSTER-IP   EXTERNAL-IP        PORT(S)
external-api   ExternalName   <none>       example.com        <none>
```

No ClusterIP, no ports. Prove it is a pure DNS alias:

```bash
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup external-api.devboard.svc.cluster.local
```

You get a CNAME to `example.com`. Nothing is proxied; the pod connects directly.

### Step 6: port-forward, and when each tool is right

```bash
kubectl port-forward -n devboard svc/devboard-frontend 8090:80
```

<http://localhost:8090> works too. Note `svc/` — forwarding to a Service picks
one pod behind it; it does **not** load balance across them.

| Tool | Reach | Use for |
|---|---|---|
| `port-forward` | one client, one pod | debugging, a quick look |
| ClusterIP | inside the cluster | service-to-service |
| NodePort | node IP + high port | dev, on-prem behind your own LB |
| LoadBalancer | public IP, cloud only | one entry point, costs money per Service |
| Ingress (Day 20) | one LB, many services by host/path | production HTTP |

---

## Validate

```bash
kubectl apply -f solution/frontend-deployment.yaml
kubectl apply -f solution/frontend-service-nodeport.yaml
kubectl rollout status deployment/devboard-frontend -n devboard

kubectl get svc devboard-frontend -n devboard \
  -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'      # 30080

kubectl get endpoints devboard-frontend -n devboard  # populated
```

Then from your own machine:

```bash
curl -s http://localhost:30080 | head -5
# PowerShell: curl.exe -s http://localhost:30080
```

Ready for Day 08 when you can:

1. Explain how NodePort, LoadBalancer and ClusterIP relate to each other.
2. Say why `EXTERNAL-IP` is `<pending>` on kind and what would fix it.
3. State the NodePort range and what happens if you request port 80.
4. Explain the `externalTrafficPolicy` trade-off in one sentence.

---

## Break it

**A. Ask for a nodePort outside the range.**

```bash
kubectl patch svc devboard-frontend -n devboard \
  -p '{"spec":{"ports":[{"port":80,"targetPort":80,"nodePort":80}]}}'
```

```
Invalid value: 80: provided port is not in the valid range.
The range of valid ports is 30000-32767
```

**B. Two Services claiming the same nodePort.**

```bash
kubectl create service nodeport clash --tcp=80:80 --node-port=30080 -n devboard
# Invalid value: 30080: provided port is already allocated
```

nodePorts are a cluster-wide finite resource, about 2700 of them. Another reason
NodePort does not scale as an exposure strategy.

**C. A nodePort with no host mapping (the kind trap).**

```bash
kubectl patch svc devboard-frontend -n devboard \
  -p '{"spec":{"ports":[{"port":80,"targetPort":80,"nodePort":31234}]}}'

curl -s --max-time 3 http://localhost:31234 || echo "FAILED as expected"
```

The Service is perfectly healthy; the port is simply not published out of the
Docker container. Prove that by hitting it from inside the cluster:

```bash
NODE_IP=$(kubectl get node devops-worker \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "$NODE_IP:31234" | head -2
```

Works from inside, fails from outside. Restore 30080:

```bash
kubectl apply -f solution/frontend-service-nodeport.yaml
```

**D. externalTrafficPolicy Local with an unlucky pod placement.**

Set `Local`, scale to 1 replica, and hit `localhost:30080`. If the pod is not on
the control-plane node (the one with the host port mapping), you get connection
refused from your browser through a perfectly healthy Service. This exact
interaction bites people on real clusters when a node's pods are drained.

---

## Interview questions

<details>
<summary><b>1. Explain the Service types and how they relate.</b></summary>

ClusterIP is a cluster-internal virtual IP, the default. NodePort is ClusterIP
plus a port in the 30000-32767 range opened on every node. LoadBalancer is
NodePort plus a cloud-provisioned external load balancer pointing at those node
ports. ExternalName is different in kind: no proxying at all, just a CNAME from
CoreDNS to an external hostname.
</details>

<details>
<summary><b>2. Why is EXTERNAL-IP pending on a local cluster?</b></summary>

`type: LoadBalancer` only records intent. A cloud-controller-manager must watch
for it, call the cloud API to provision a load balancer, and write the address
into status. Local clusters have no such controller, so it stays pending.
MetalLB or cloud-provider-kind can fill that role on bare metal.
</details>

<details>
<summary><b>3. Is a NodePort open on all nodes or only nodes running the pod?</b></summary>

All nodes by default. kube-proxy programs the rule everywhere and forwards
across nodes as needed. With `externalTrafficPolicy: Local` only nodes hosting a
Ready pod accept traffic, which preserves the source IP and avoids a hop, at the
cost of some nodes refusing connections.
</details>

<details>
<summary><b>4. Why not use NodePort in production?</b></summary>

Arbitrary high ports clients must know, node IPs clients must know and that
change, a hard cluster-wide cap of about 2700 ports, no TLS termination, no
host or path routing, and no failover if a node dies. Production HTTP goes
through an ingress controller behind a single LoadBalancer.
</details>

<details>
<summary><b>5. You have 30 microservices to expose. How?</b></summary>

One LoadBalancer Service in front of an ingress controller, 30 ClusterIP
Services behind it, and Ingress or Gateway API rules routing by hostname and
path. One cloud load balancer instead of thirty, plus centralised TLS, rate
limiting and observability.
</details>

<details>
<summary><b>6. How do you preserve the client's real IP?</b></summary>

Set `externalTrafficPolicy: Local` so no SNAT occurs, or terminate at an L7
proxy and read `X-Forwarded-For`. On cloud NLBs, proxy protocol is another
option. Understand the cost: with `Local`, nodes without pods stop accepting
traffic and load distribution follows pod placement.
</details>

<details>
<summary><b>7. When is ExternalName the right tool?</b></summary>

When you want a stable in-cluster name for something outside the cluster that
clients resolve by DNS - a managed database, a SaaS API. Later you can replace
the CNAME with a real in-cluster Service without touching application config. It
does not help clients given raw IPs, and TLS SNI still carries the external name.
</details>

<details>
<summary><b>8. Difference between a Service and an Ingress?</b></summary>

A Service is L4: it balances TCP/UDP connections to pods selected by labels. An
Ingress is L7 HTTP routing - hostnames, paths, TLS termination, rewrites - and
it routes *to* ClusterIP Services rather than replacing them. An Ingress object
does nothing at all without an ingress controller running to implement it.
</details>

---

## Cheat card

```bash
kubectl get svc -A
kubectl describe svc devboard-frontend -n devboard

# expose an existing deployment quickly
kubectl expose deployment devboard-frontend --type=NodePort \
  --port=80 --target-port=80 -n devboard

# read the allocated nodePort
kubectl get svc devboard-frontend -n devboard -o jsonpath='{.spec.ports[0].nodePort}'

kubectl get nodes -o wide                 # node IPs
kubectl port-forward -n devboard svc/devboard-frontend 8090:80
docker port devops-control-plane          # which ports kind published
```

| Field | Meaning |
|---|---|
| `port` | Service port; clients connect here |
| `targetPort` | container port; may be a name |
| `nodePort` | 30000-32767, opened on every node |
| `externalTrafficPolicy` | `Cluster` (spread, SNAT) or `Local` (real source IP) |
| `clusterIP: None` | headless: DNS returns pod IPs |
| `sessionAffinity: ClientIP` | pin a client IP to one pod (crude stickiness) |

---

**Next: [Day 08 - Build and load the DevBoard images](../day-08-build-and-load-app-images/)**
