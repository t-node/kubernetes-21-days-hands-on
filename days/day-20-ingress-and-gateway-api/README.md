# Day 20 — Ingress and the Gateway API

**Time:** 75-90 minutes
**Prerequisites:** Days 06-07 (Services), Day 12 (the full stack)

NodePort got DevBoard into your browser, badly. Today you do it properly — and
then migrate to the Gateway API, which is where Kubernetes ingress is going.

---

## Part 1 - Concepts

### 20.1 Why Services are not enough for HTTP

| Need | Can a Service do it? |
|---|---|
| Route `api.example.com` and `app.example.com` to different backends | no — L4, no idea what a Host header is |
| Route `/api` and `/` to different backends | no |
| Terminate TLS | no |
| One public IP for 30 services | no — one LoadBalancer each, each costing money |
| Rewrite paths, set headers, rate limit | no |

Services are **L4**: they balance TCP connections by label selector. Everything
above is **L7** and requires something that parses HTTP. That is an **Ingress
controller**.

### 20.2 Ingress is an object PLUS a controller

Two separate things, and the distinction matters:

- **The Ingress object** is a set of routing rules. Inert data.
- **The Ingress controller** is a pod running a real proxy — nginx, HAProxy,
  Traefik, Envoy — that watches Ingress objects and reconfigures itself.

> **An Ingress object with no controller installed does nothing at all.**
> No error, no warning, no event. `ADDRESS` just stays empty. This is the number
> one Ingress confusion.

```
        internet
            |
   one LoadBalancer Service
            |
   +--------v---------+
   | ingress-nginx    |  <- the controller: a proxy watching the API
   | (pods)           |
   +--------+---------+
       |         |             routes by Host and path
   +---v----+ +--v------+
   |frontend| | backend |      <- ordinary ClusterIP Services
   +--------+ +---------+
```

**One** cloud load balancer, many services behind it. That is the cost argument
from Day 07, resolved.

### 20.3 The Ingress object

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: devboard
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2    # controller-SPECIFIC
spec:
  ingressClassName: nginx           # WHICH controller should act on this
  tls:
    - hosts: [devboard.local]
      secretName: devboard-tls      # a kubernetes.io/tls Secret (Day 10)
  rules:
    - host: devboard.local
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: devboard-frontend
                port:
                  number: 80
```

`pathType` has three values and they are frequently misused:

| pathType | Matches |
|---|---|
| `Exact` | that path exactly, nothing else |
| `Prefix` | split on `/` — `/api` matches `/api/x` but **not** `/apifoo` |
| `ImplementationSpecific` | whatever the controller decides — regex, for nginx |

**The great weakness of Ingress is annotations.** Anything beyond basic
host/path routing — rewrites, timeouts, rate limits, auth, CORS, canary weights
— is a controller-specific annotation. Your manifests become nginx-specific, and
moving to Traefik means rewriting them. That non-portability is precisely why
the Gateway API exists.

### 20.4 The `/api` rewrite, for this app specifically

From Day 12: the browser calls `/api/tasks`, but the Go router serves `/tasks`.
`vite preview` was stripping the prefix. Once an Ingress routes `/api` straight
to the backend Service, **the Ingress must do that stripping instead**:

```yaml
annotations:
  nginx.ingress.kubernetes.io/rewrite-target: /$2
...
  - path: /api(/|$)(.*)
    pathType: ImplementationSpecific
```

Capture group `$2` is everything after `/api/`, so `/api/tasks` becomes
`/tasks`. Forget it and every API call 404s while every pod looks perfectly
healthy. You will do exactly that in Break It.

### 20.5 The Gateway API: why Ingress is being replaced

Ingress has been stable and essentially frozen since 2020. Its problems:

1. **Annotation sprawl** — everything useful is vendor-specific.
2. **No role separation** — one object mixes infrastructure concerns (which load
   balancer, which certificate) with application concerns (which path goes
   where), so a developer editing a route can change TLS.
3. **HTTP only** — no first-class gRPC, TCP or UDP.
4. **No traffic splitting** — canary weights need annotations, where supported
   at all.

The **Gateway API** replaces it with three role-oriented resources:

| Resource | Owned by | Says |
|---|---|---|
| **GatewayClass** | infrastructure provider | "this kind of gateway exists" (like a StorageClass) |
| **Gateway** | cluster operator | "listen on :443 for `*.example.com` with this certificate" |
| **HTTPRoute** | **application developer** | "`/api` goes to my backend Service" |

That separation is the headline feature. A platform team owns the Gateway and
its TLS; app teams own HTTPRoutes in their own namespaces and cannot touch
infrastructure. RBAC maps onto it cleanly.

And the things that needed annotations become **typed API fields**:

```yaml
rules:
  - matches:
      - path: { type: PathPrefix, value: /api }
        headers:
          - name: x-canary
            value: "true"
    filters:
      - type: URLRewrite
        urlRewrite:
          path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
    backendRefs:
      - name: backend-v2
        port: 8080
        weight: 90              # traffic splitting, first-class
      - name: backend-v1
        port: 8080
        weight: 10
```

Header matching, path rewriting and weighted splitting — portable across
implementations and validated by the API server.

### 20.6 Status and timeline — get this right in interviews

- **Ingress is not deprecated in Kubernetes itself.** The
  `networking.k8s.io/v1` Ingress API is stable and is not being removed. Expect
  it in production for years.
- **It is effectively frozen.** No new features; the investment is all in the
  Gateway API.
- **Gateway API v1.0 (GA)** shipped in October 2023 — GatewayClass, Gateway and
  HTTPRoute are `v1`. GRPCRoute reached GA later; TCPRoute, UDPRoute and
  TLSRoute remain experimental.
- **It is not built in.** You install the CRDs and an implementation yourself:
  Envoy Gateway, Istio, Contour, Cilium, NGINX Gateway Fabric, Traefik, or a
  cloud one (GKE Gateway, AWS Gateway API Controller).
- **Ingress-NGINX specifically** is in maintenance mode, with the project
  pointing at **InGate**, a Gateway API implementation, as its successor.
  Operators are actively planning migrations.

**A good interview answer:** *"Ingress is stable but frozen; the Gateway API is
GA for HTTP and is where new development goes. For a new platform I would start
with the Gateway API. For existing Ingress in production I would migrate
incrementally — both run side by side, and `ingress2gateway` automates the first
pass."*

### 20.7 Migration is mechanical

| Ingress | Gateway API |
|---|---|
| `ingressClassName` | `GatewayClass` plus a `Gateway` |
| `spec.tls` | `Gateway.listeners[].tls` |
| `spec.rules[].host` | `HTTPRoute.hostnames` |
| `spec.rules[].http.paths` | `HTTPRoute.rules[].matches` |
| `backend.service` | `backendRefs` |
| `rewrite-target` annotation | `filters[].urlRewrite` |
| canary annotations | `backendRefs[].weight` |

The official tool does most of it:

```bash
ingress2gateway print --input-file=ingress.yaml --providers=ingress-nginx
```

They coexist, so you can migrate one route at a time.

---

## Part 2 - Hands-on lab

### Step 1: Install ingress-nginx

Your kind config already prepared for this — the control-plane node has
`ingress-ready=true` and host ports 8080/8443 mapped to the node's 80/443.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

kubectl get pods,svc -n ingress-nginx
kubectl get ingressclass
```

Note the deployment used is the **kind provider** variant: it runs the
controller as a DaemonSet with `hostPort: 80/443` on the `ingress-ready` node,
instead of expecting a cloud LoadBalancer.

### Step 2: Prove an Ingress does nothing without matching the controller

```bash
kubectl apply -f solution/01-ingress-basic.yaml
kubectl get ingress -n devboard
```

```
NAME       CLASS   HOSTS             ADDRESS     PORTS   AGE
devboard   nginx   devboard.local    localhost   80      20s
```

`ADDRESS` populated means the controller claimed it. Confirm:

```bash
kubectl describe ingress devboard -n devboard | grep -A5 Events
# Normal  Sync  nginx-ingress-controller  Scheduled for sync
```

Now test it. The host must match, so send a `Host` header:

```bash
curl -s -H "Host: devboard.local" http://localhost:8080/ | head -5
curl -s -H "Host: devboard.local" http://localhost:8080/api/tasks | head -c 200; echo
```

Or add a hosts entry so a browser works:

```bash
# Linux/macOS:  sudo sh -c 'echo "127.0.0.1 devboard.local" >> /etc/hosts'
# Windows (admin PowerShell):
#   Add-Content C:\Windows\System32\drivers\etc\hosts "127.0.0.1 devboard.local"
```

Then open <http://devboard.local:8080>.

### Step 3: Watch the /api rewrite work

Compare what reaches the backend, with and without the rewrite:

```bash
# WITH the rewrite (solution/01) -- /api/tasks becomes /tasks
curl -s -o /dev/null -w "with rewrite:    %{http_code}\n" \
  -H "Host: devboard.local" http://localhost:8080/api/tasks

# WITHOUT it
kubectl apply -f solution/02-ingress-no-rewrite.yaml
sleep 5
curl -s -o /dev/null -w "without rewrite: %{http_code}\n" \
  -H "Host: devboard.local" http://localhost:8080/api/tasks
curl -s -H "Host: devboard.local" http://localhost:8080/api/tasks
# 404 page not found     <- the Gin router has no /api/tasks route

kubectl apply -f solution/01-ingress-basic.yaml
```

Every pod is healthy, every Service has endpoints, and the API is completely
broken. **Path rewriting is the single most common Ingress bug.**

### Step 4: Host-based routing

```bash
kubectl apply -f solution/03-ingress-hosts.yaml

curl -s -o /dev/null -w "app: %{http_code}\n" -H "Host: app.devboard.local"  http://localhost:8080/
curl -s -o /dev/null -w "api: %{http_code}\n" -H "Host: api.devboard.local"  http://localhost:8080/tasks
curl -s -o /dev/null -w "bad: %{http_code}\n" -H "Host: nope.devboard.local" http://localhost:8080/
```

Two hostnames, two backends, **one load balancer**. With `api.devboard.local`
the backend is reached at its own root, so no rewrite is needed — a cleaner
design than path-based routing when you control DNS.

The unmatched host returns 404 from the default backend.

### Step 5: TLS

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=devboard.local/O=devboard" \
  -addext "subjectAltName=DNS:devboard.local,DNS:*.devboard.local"

kubectl create secret tls devboard-tls -n devboard \
  --cert=tls.crt --key=tls.key --dry-run=client -o yaml | kubectl apply -f -
rm tls.crt tls.key

kubectl apply -f solution/04-ingress-tls.yaml
sleep 5

curl -sk -o /dev/null -w "https: %{http_code}\n" \
  -H "Host: devboard.local" https://localhost:8443/

# and the automatic HTTP -> HTTPS redirect
curl -s -o /dev/null -w "http:  %{http_code}\n" \
  -H "Host: devboard.local" http://localhost:8080/
# 308 Permanent Redirect
```

`-k` skips certificate verification because this is self-signed. In production
you would run **cert-manager**, which watches Ingress objects and obtains real
Let's Encrypt certificates automatically:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

### Step 6: Delete the NodePort — you do not need it any more

```bash
kubectl patch svc devboard-frontend -n devboard \
  -p '{"spec":{"type":"ClusterIP","ports":[{"name":"http","port":80,"targetPort":"http"}]}}'

kubectl get svc -n devboard
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080          # fails now
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: devboard.local" http://localhost:8080/   # 200
```

**Every Service in the namespace is now ClusterIP.** Nothing is exposed except
through the ingress controller — one entry point, one place for TLS, one place
for rate limiting and WAF rules. That is the production shape.

### Step 7: Migrate to the Gateway API

Install the CRDs — they are **not** part of Kubernetes:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl get crd | grep gateway
kubectl api-resources | grep gateway
```

Then an implementation. **Envoy Gateway** works well on kind:

```bash
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.2.6/install.yaml
kubectl wait --timeout=300s -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available
kubectl get gatewayclass
```

Now the three objects:

```bash
kubectl apply -f solution/05-gatewayclass-note.yaml   # read the comments
kubectl apply -f solution/06-gateway.yaml
kubectl apply -f solution/07-httproute.yaml

kubectl get gateway,httproute -n devboard
kubectl describe gateway devboard-gateway -n devboard | grep -A10 Status
```

Look at the `Status` block. Gateway API resources report **detailed conditions**
— `Accepted`, `Programmed`, `ResolvedRefs` — with real messages. Compare that
with an Ingress, whose entire feedback is whether `ADDRESS` filled in. Debugging
is genuinely better.

Envoy Gateway creates its own Service; find and reach it:

```bash
kubectl get svc -n envoy-gateway-system
SVC=$(kubectl get svc -n envoy-gateway-system -o name | grep envoy-devboard | head -1)
kubectl port-forward -n envoy-gateway-system $SVC 8090:80 &
sleep 3

curl -s -o /dev/null -w "app: %{http_code}\n" -H "Host: devboard.local" http://localhost:8090/
curl -s -H "Host: devboard.local" http://localhost:8090/api/tasks | head -c 200; echo
kill %1
```

Same routing, same rewrite — but expressed as **typed fields** rather than an
nginx annotation:

```bash
grep -A6 "filters:" solution/07-httproute.yaml
```

> **If the Envoy Gateway install is heavy on your machine**, skip Step 7's
> installation and just read `solution/06-gateway.yaml` and
> `solution/07-httproute.yaml` alongside `solution/01-ingress-basic.yaml`. The
> three-file diff *is* the lesson; the exercise is understanding the mapping,
> not running two controllers.

### Step 8: Traffic splitting — the thing Ingress cannot do

```bash
kubectl apply -f solution/08-httproute-canary.yaml
kubectl describe httproute devboard-canary -n devboard | grep -A8 Rules
```

```yaml
backendRefs:
  - name: backend
    port: 8080
    weight: 90
  - name: backend-canary
    port: 8080
    weight: 10
```

Two lines of standard API, no annotations, portable across every
implementation. On Day 05 you approximated this with replica ratios; here it is
a first-class field.

### Step 9: Run the migration tool

```bash
# go install github.com/kubernetes-sigs/ingress2gateway@latest
ingress2gateway print --input-file=solution/01-ingress-basic.yaml \
  --providers=ingress-nginx
```

It emits a Gateway plus HTTPRoutes. It handles the standard cases and flags what
it cannot translate — which is exactly the annotations that were never portable
in the first place.

---

## Validate

```bash
kubectl get pods -n ingress-nginx
kubectl apply -f solution/01-ingress-basic.yaml
sleep 10

kubectl get ingress devboard -n devboard \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'      # localhost

curl -s -o /dev/null -w "UI:    %{http_code}\n" -H "Host: devboard.local" http://localhost:8080/
curl -s -o /dev/null -w "tasks: %{http_code}\n" -H "Host: devboard.local" http://localhost:8080/api/tasks
curl -s -H "Host: devboard.local" http://localhost:8080/api/projects | head -c 120; echo
```

Ready for Day 21 when you can:

1. Explain why an Ingress object alone does nothing.
2. Explain what `rewrite-target` does here and what breaks without it.
3. Name the three Gateway API resources and who owns each.
4. State accurately whether Ingress is deprecated.

---

## Break it

**A. No ingressClassName.**

```bash
kubectl apply -f solution/BAD-01-no-class.yaml
kubectl get ingress -n devboard
# ADDRESS stays empty for orphan-ingress
```

No controller claims it. No error, no event, nothing happens. If a default
IngressClass is marked with the `ingressclass.kubernetes.io/is-default-class`
annotation it would be picked up — otherwise the object is inert.

```bash
kubectl delete -f solution/BAD-01-no-class.yaml
```

**B. Backend Service does not exist.**

```bash
kubectl apply -f solution/BAD-02-wrong-service.yaml
sleep 5
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: broken.local" http://localhost:8080/
# 503
kubectl describe ingress broken-backend -n devboard | grep -A5 Events
kubectl delete -f solution/BAD-02-wrong-service.yaml
```

**503 from the ingress controller** means "I have no healthy upstream". Compare
with the **404** from Break It in Step 3, which came from the *application*.
Different numbers, different layers — learning to read that difference is worth
real debugging time.

**C. Wrong pathType.**

```bash
kubectl apply -f solution/BAD-03-exact-path.yaml
sleep 5
curl -s -o /dev/null -w "/api/tasks: %{http_code}\n" -H "Host: exact.local" http://localhost:8080/api/tasks
curl -s -o /dev/null -w "/api:       %{http_code}\n" -H "Host: exact.local" http://localhost:8080/api
kubectl delete -f solution/BAD-03-exact-path.yaml
```

`pathType: Exact` matches `/api` and nothing beneath it.

**D. Two Ingresses claiming the same host and path.**

```bash
kubectl apply -f solution/BAD-04-conflicting.yaml
sleep 5
for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " -H "Host: devboard.local" http://localhost:8080/; done; echo
kubectl describe ingress conflicting -n devboard | grep -A5 Events
kubectl delete -f solution/BAD-04-conflicting.yaml
```

Behaviour is **controller-specific** and mostly undefined — ingress-nginx
generally lets the oldest object win and logs a warning. Nothing in the API
prevents you from creating the conflict, which is one more argument for the
Gateway API, where `HTTPRoute` conflict resolution is specified.

---

## Interview questions

<details>
<summary><b>1. What is an Ingress and what does it need to work?</b></summary>

An Ingress is an API object holding L7 HTTP routing rules - hostnames, paths,
TLS - that point at ClusterIP Services. It does nothing on its own: an ingress
**controller** must be running to watch those objects and configure an actual
proxy such as nginx, HAProxy or Envoy. An Ingress with no matching controller
produces no error and no address; it is simply inert.
</details>

<details>
<summary><b>2. Service vs Ingress?</b></summary>

A Service is L4: it load balances TCP or UDP connections to pods selected by
labels, with no understanding of HTTP. An Ingress is L7: host and path routing,
TLS termination, rewrites and header manipulation - and it routes *to*
ClusterIP Services rather than replacing them. The practical driver is cost and
consolidation: one LoadBalancer in front of an ingress controller serves many
services instead of one LoadBalancer each.
</details>

<details>
<summary><b>3. Is Ingress deprecated?</b></summary>

Not in Kubernetes itself - `networking.k8s.io/v1` Ingress is stable and is not
being removed. But it has been feature-frozen since 2020 and all new development
goes into the Gateway API, which reached GA for HTTP in October 2023. Separately,
the Ingress-NGINX *project* is in maintenance mode and points at InGate, a
Gateway API implementation, as its successor - which is what people usually mean
when they say "ingress is going away". For new platforms, start with the Gateway
API; for existing ones, migrate incrementally.
</details>

<details>
<summary><b>4. What problems does the Gateway API solve?</b></summary>

Four. Portability: features that were vendor-specific annotations - rewrites,
timeouts, traffic weights - become typed API fields. Role separation:
GatewayClass belongs to the infrastructure provider, Gateway to the cluster
operator, HTTPRoute to the application developer, so RBAC can be split cleanly
and app teams cannot alter TLS. Protocol coverage: first-class gRPC, and TCP/UDP
routes in experimental form. And expressiveness: header and query matching,
weighted backends, and richer status conditions for debugging.
</details>

<details>
<summary><b>5. How would you migrate from Ingress to the Gateway API?</b></summary>

Incrementally - they coexist. Install the CRDs and an implementation, create a
Gateway that mirrors your existing ingress listeners and TLS, then convert one
Ingress at a time into HTTPRoutes, shifting DNS or the load balancer per route
and verifying as you go. `ingress2gateway` automates the mechanical translation
and reports what it cannot convert, which is precisely the annotation-based
behaviour that was never portable.
</details>

<details>
<summary><b>6. Your Ingress returns 404 for /api but the backend is healthy. Why?</b></summary>

Most likely a missing or wrong path rewrite: the browser requests `/api/tasks`
and the Ingress forwards `/api/tasks` unchanged, but the application only serves
`/tasks`. With ingress-nginx that is `rewrite-target` plus a capture group in
the path; with the Gateway API it is a `URLRewrite` filter. Distinguish it from
a 503, which comes from the controller having no healthy upstream rather than
from the application.
</details>

<details>
<summary><b>7. How do you get TLS certificates in Kubernetes?</b></summary>

cert-manager. It watches Ingress or Gateway objects, requests certificates from
an issuer - usually Let's Encrypt via ACME with HTTP-01 or DNS-01 - stores them
in `kubernetes.io/tls` Secrets, and renews them automatically. You annotate the
Ingress with a `cluster-issuer` and it handles the rest. Manual certificates
work but nobody wants a 90-day renewal on a calendar.
</details>

<details>
<summary><b>8. How do you do canary deployments at the ingress layer?</b></summary>

With the Gateway API, weighted `backendRefs` on an HTTPRoute - portable and
first-class. With ingress-nginx, a second Ingress carrying
`nginx.ingress.kubernetes.io/canary: "true"` plus a weight or header annotation.
With a service mesh, weighted destination rules. For automation, Flagger or Argo
Rollouts drive the weights while watching metrics and roll back automatically.
</details>

<details>
<summary><b>9. Ingress controller vs API gateway vs service mesh?</b></summary>

An ingress controller handles north-south traffic entering the cluster: routing,
TLS, basic rate limiting. An API gateway adds product concerns - authentication,
API keys, quotas, monetisation, request transformation - and often sits at the
edge or replaces the ingress controller. A service mesh handles east-west
traffic between services: mTLS, retries, circuit breaking, fine-grained traffic
shifting and distributed tracing, usually via sidecars. They overlap: Istio and
Envoy Gateway can do both directions.
</details>

---

## Cheat card

```bash
# install (kind provider variant)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

kubectl get ingress -A
kubectl get ingressclass
kubectl describe ingress devboard -n devboard        # Events say if it was claimed

# test with a Host header instead of editing /etc/hosts
curl -H "Host: devboard.local" http://localhost:8080/api/tasks
curl -k -H "Host: devboard.local" https://localhost:8443/

# what config did nginx actually generate?
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf | grep -A10 devboard
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50

# gateway api
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl get gatewayclass,gateway,httproute -A
kubectl describe gateway devboard-gateway -n devboard    # rich status conditions
```

| Status code | Comes from | Usually means |
|---|---|---|
| 404 | your **application** | path rewrite wrong, or route not matched |
| 503 | the **controller** | no healthy upstream — Service or endpoints missing |
| 502 | the **controller** | upstream connection refused or errored |
| 308 | the controller | HTTP→HTTPS redirect (expected with TLS) |

| Ingress | Gateway API |
|---|---|
| `ingressClassName` | GatewayClass + Gateway |
| `spec.tls` | `Gateway.listeners[].tls` |
| `rules[].host` | `HTTPRoute.hostnames` |
| `rewrite-target` annotation | `filters[].urlRewrite` |
| canary annotations | `backendRefs[].weight` |

---

**Next: [Day 21 - Break and fix](../day-21-break-and-fix-troubleshooting/)**
