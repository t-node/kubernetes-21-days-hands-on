# CKA 25 — Ingress and Gateway API in Depth

**Time:** 110-130 minutes
**Prerequisites:** [Day 20](../../days/day-20-ingress-and-gateway-api/), [CKA 23](../23-service-networking/), [CKA 24](../24-dns-and-coredns/)
**Source lectures:** 229, 233, 235, 236

[Day 20](../../days/day-20-ingress-and-gateway-api/) built an Ingress, added TLS,
and migrated it to the Gateway API. This assignment opens the controller up:
what it *generates*, what is actually in the data path, how path matching really
resolves, and the parts of the Gateway API that exist because Ingress could not
express them.

---

## Part 1 - Concepts

### 25.1 The Service is not in the data path

This surprises almost everyone, and it changes how you debug.

```
   client
     |
     v
  ingress-nginx pod
     |  reads Ingress objects  -> which Service?
     |  reads EndpointSlices   -> which POD IPs?
     |
     +---------> 10.244.1.7:8080     directly to a pod
     +---------> 10.244.2.9:8080
```

**The controller resolves the Service to its endpoints and proxies straight to
pod IPs.** The ClusterIP is used as a *name* to look up endpoints, then
discarded. No `KUBE-SVC` chain, no DNAT, no kube-proxy involvement
([CKA 23](../23-service-networking/)).

Three consequences:

- **`sessionAffinity` on the Service does nothing** for Ingress traffic. The
  controller has its own affinity annotations.
- **`externalTrafficPolicy` on the backend Service does nothing** either.
- **A wrong `targetPort` still breaks it**, because the controller reads the port
  from the Service's spec even though it dials the pod.

You can read the generated upstreams directly, and Part 2 does.

> `service.spec.type` is irrelevant for an Ingress backend. **`ClusterIP` is
> correct** — making it a NodePort "so the ingress can reach it" is a
> misunderstanding that appears in a lot of tutorials.

### 25.2 `pathType` decides more than you think

```yaml
  - path: /api
    pathType: Prefix
```

| `pathType` | Matches |
|---|---|
| **`Exact`** | the path, exactly. `/api` matches `/api` and **not** `/api/` |
| **`Prefix`** | **element-wise**, split on `/`. `/api` matches `/api` and `/api/v1`, **not** `/apifoo` |
| `ImplementationSpecific` | whatever the controller wants -- for nginx, a regex |

**`Prefix` is not a string prefix.** `/api` does not match `/apiary`, because
matching happens on path *elements*. That is a deliberate difference from how
nginx's own `location` behaves, and it is part of why
`ImplementationSpecific` exists.

**The resolution rules, in order:**

1. **The longest matching path wins**, regardless of which rule declared it.
2. If two paths are equally long, **`Exact` beats `Prefix`**.
3. Host matching happens first: a rule with a matching `host` beats one without.

So with `/` (Prefix), `/api` (Prefix) and `/api/v1/health` (Exact) defined, a
request for `/api/v1/health` hits the third, `/api/v1/users` hits the second, and
`/dashboard` hits the first. **You do not control this by ordering the YAML.**

### 25.3 Annotations are the controller's API

The Ingress spec covers hosts, paths and TLS. **Everything else is annotations**,
and they are specific to one controller:

```yaml
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
```

**This is the central weakness of Ingress and the reason the Gateway API
exists.** An Ingress written for ingress-nginx does not work on Traefik, HAProxy
or a cloud controller — the hosts and paths port, and everything that makes it
useful does not.

**`rewrite-target` with capture groups** is the one to know:

```yaml
    nginx.ingress.kubernetes.io/rewrite-target: /$2
  ...
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
```

`$2` is the second capture group — everything after `/api/`. A request for
`/api/v1/users` reaches the backend as `/v1/users`.

**`pathType` must be `ImplementationSpecific` for this**, because `/api(/|$)(.*)`
is a regex and neither `Exact` nor `Prefix` permits one. Using `Prefix` with a
regex path is the most common ingress-nginx mistake — it does not error, it
simply never matches.

> **`configuration-snippet` injects raw nginx config.** It is disabled by default
> in recent versions because it is an escalation path: anyone able to create an
> Ingress in any namespace could inject configuration affecting the whole
> controller. Enabling it is a cluster-wide security decision.

### 25.4 IngressClass

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: k8s.io/ingress-nginx
```

```yaml
# on the Ingress
spec:
  ingressClassName: nginx
```

**`ingressClassName` is a field; `kubernetes.io/ingress.class` was an annotation
and is deprecated.** Both still appear in the wild, and a controller may honour
either — check which before assuming an Ingress is unclaimed.

**An Ingress with no class and no default class is claimed by nobody.** It sits
with an empty `ADDRESS` column forever — which is also exactly what a typo in
`ingressClassName` looks like:

```bash
kubectl get ingress          # ADDRESS empty == nothing picked it up
kubectl get ingressclass
```

**Several controllers can coexist** — internal and external, or nginx and a cloud
one — each with its own IngressClass, each ignoring Ingresses that name the
other.

### 25.5 The Gateway API separates roles

Ingress puts infrastructure and routing in one object owned by one team. The
Gateway API splits them deliberately:

| Object | Owned by | Says |
|---|---|---|
| **`GatewayClass`** | the platform / vendor | "this is the implementation" |
| **`Gateway`** | the **cluster operator** | listeners, ports, TLS, **who may attach** |
| **`HTTPRoute`** | the **application team** | hostnames, paths, filters, backends |

```yaml
kind: Gateway
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: {gateway-access: "true"}
```

**`allowedRoutes` is the piece Ingress has no equivalent for.** The operator
decides which namespaces may attach routes to a listener — `Same`, `All`, or a
label selector. An application team cannot claim a hostname on a Gateway they
were not granted.

Attachment is by reference, from the route's side:

```yaml
kind: HTTPRoute
spec:
  parentRefs:
    - name: my-gateway
      namespace: infra
      sectionName: http        # which LISTENER, optionally
  hostnames: ["app.example.com"]
```

**And the Gateway must agree.** If it does not, the route is created successfully
and does nothing — the rejection appears in **status**:

```bash
kubectl get httproute my-route -o jsonpath='{.status.parents[*].conditions}' | jq
```

```
"type": "Accepted", "status": "False", "reason": "NotAllowedByListeners"
```

**Reading `status.parents` is the single most important Gateway API debugging
skill.** Unlike an Ingress, which fails silently, an HTTPRoute tells you exactly
why it was refused.

### 25.6 Cross-namespace references need permission

An HTTPRoute in `apps` cannot send traffic to a Service in `data` just by naming
it. That would let any namespace expose any other namespace's Services.

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-apps-to-data
  namespace: data              # in the TARGET namespace
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: apps
  to:
    - group: ""
      kind: Service
      name: db                 # optional -- omit for all Services
```

**The grant lives in the namespace being referenced**, and is created by that
namespace's owner. Without it the route reports
`ResolvedRefs: False, reason: RefNotPermitted`.

This is a capability Ingress lacks entirely: an Ingress can only reference
Services in its own namespace, full stop.

### 25.7 Filters replace annotations

The things you needed annotations for are typed fields:

```yaml
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
            - {name: X-Env, value: prod}
      - type: RequestRedirect
        requestRedirect:
          scheme: https
          statusCode: 301
```

**These are portable.** A `URLRewrite` filter behaves the same on Envoy Gateway,
Istio, Cilium and a cloud implementation — which is the whole argument for the
API. Compare with `nginx.ingress.kubernetes.io/rewrite-target`, which works on
exactly one controller.

And traffic splitting, which Ingress cannot express at all:

```yaml
      backendRefs:
        - {name: web-v1, port: 80, weight: 90}
        - {name: web-v2, port: 80, weight: 10}
```

---

## Part 2 - Hands-on lab

The ingress-nginx controller from
[Day 20](../../days/day-20-ingress-and-gateway-api/) is the prerequisite:

```bash
kubectl get pods -n ingress-nginx
kubectl get ingressclass
```

If it is not installed, do Day 20's Step 1 first.

```bash
kubectl create namespace cka25
kubectl config set-context --current --namespace=cka25
kubectl apply -f solution/01-backends.yaml
kubectl rollout status deployment/root --timeout=120s
kubectl rollout status deployment/api  --timeout=120s
```

Add the hostnames to your workstation so `curl` sends the right `Host` header —
or skip that and pass `-H` explicitly, which the commands below do.

### Step 1: Read what the controller generated

```bash
kubectl apply -f solution/02-pathtype-precedence.yaml
sleep 5
CTRL=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf | grep -c "^"
```

Several thousand lines, all generated from your Ingress objects. Find yours:

```bash
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf \
  | grep -A30 "server_name paths.local"
```

**Every `location` block corresponds to one path entry**, and the order nginx
emitted them in is not the order you wrote them.

Now the part that matters:

```bash
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf \
  | grep -B3 -A12 "upstream_balancer" | head -30

kubectl exec -n ingress-nginx "$CTRL" -- \
  curl -s http://127.0.0.1:10246/configuration/backends 2>/dev/null \
  | tr ',' '\n' | grep -E '"address"|"port"|"name"' | head -20
```

Compare what it lists against:

```bash
kubectl get svc api -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get endpointslices -l kubernetes.io/service-name=api \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

**The controller's backend list contains the pod IPs, not the ClusterIP** (25.1).
The Service was used to *find* them and is not in the data path.

Prove it by scaling:

```bash
kubectl scale deployment/api --replicas=4
kubectl rollout status deployment/api --timeout=90s
sleep 5
kubectl exec -n ingress-nginx "$CTRL" -- \
  curl -s http://127.0.0.1:10246/configuration/backends 2>/dev/null \
  | tr ',' '\n' | grep -c '"address"'
kubectl scale deployment/api --replicas=2
```

**The controller watches EndpointSlices and updates itself** — the same input
kube-proxy uses ([CKA 23](../23-service-networking/)), consumed by a different
consumer.

### Step 2: Path precedence

`02-pathtype-precedence.yaml` deliberately lists its rules in an unhelpful
order. Predict each answer before you run it:

```bash
H="-H Host:paths.local"
curl -s $H http://localhost:8080/                      # ?
curl -s $H http://localhost:8080/dashboard             # ?
curl -s $H http://localhost:8080/api                   # ?
curl -s $H http://localhost:8080/api/v1/users          # ?
curl -s $H http://localhost:8080/api/v1/health         # ?
curl -s $H http://localhost:8080/api/v1/healthcheck    # ?
```

```
ROOT-...          /              -> the / Prefix rule
ROOT-...          /dashboard     -> still the / rule; nothing longer matches
API-... path=/api
API-... path=/api/v1/users       -> /api Prefix, longest match
HEALTH-EXACT      /api/v1/health -> Exact beats the equally long Prefix
API-... path=/api/v1/healthcheck -> Exact did NOT match; /api Prefix did
```

**The last two are the point.** `/api/v1/health` and `/api/v1/healthcheck` differ
by five characters and go to different backends, because `Exact` matches the
whole path or nothing (25.2).

And the element-wise rule:

```bash
curl -s $H http://localhost:8080/apiary
```

**`ROOT`, not `API`.** `/api` as a `Prefix` does not match `/apiary` — matching
is on path elements, not string prefixes.

### Step 3: The rewrite, and the way it is usually broken

```bash
kubectl apply -f solution/03-rewrite-correct.yaml
sleep 5
curl -s -H "Host: rewrite.local" http://localhost:8080/api/v1/users
```

```
API-api-xxxx path=/v1/users
```

**The backend received `/v1/users`** — `/api` was stripped by `$2` (25.3). The
backend never knows it was mounted under a prefix.

Now the same thing with one field changed:

```bash
kubectl apply -f solution/04-rewrite-BAD.yaml
sleep 5
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: broken.local" http://localhost:8080/api/v1/users
```

```
404
```

```bash
kubectl get ingress rewrite-broken
kubectl describe ingress rewrite-broken | tail -8
```

**`kubectl` shows nothing wrong.** The object is valid, the ADDRESS is populated,
there are no warning events. The only difference is `pathType: Prefix` on a regex
path — so nginx generated a literal `location /api(/|$)(.*)` that nothing will
ever request.

```bash
diff solution/03-rewrite-correct.yaml solution/04-rewrite-BAD.yaml
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf \
  | grep -A3 "server_name broken.local" | head -12
```

**Reading the generated config is how you diagnose this**, and it is the reason
Step 1 came first.

```bash
kubectl delete -f solution/04-rewrite-BAD.yaml
```

### Step 4: The Ingress nobody claimed

```bash
kubectl apply -f solution/05-no-class-BAD.yaml
sleep 10
kubectl get ingress
```

```
NAME          CLASS             HOSTS          ADDRESS     PORTS   AGE
orphan        nginx-internal    orphan.local               80      10s
precedence    nginx             paths.local    localhost   80      8m
```

**An empty `ADDRESS` is the whole diagnosis** (25.4). No controller adopted it,
and none ever will:

```bash
kubectl get ingressclass
kubectl describe ingress orphan | grep -A3 Events      # nothing
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: orphan.local" http://localhost:8080/
```

`404` from the default backend, because nginx has never heard of that host.

**`ADDRESS` empty means: no matching IngressClass, a typo in
`ingressClassName`, or no default class and no class named.** Check
`kubectl get ingressclass` before anything else.

```bash
kubectl delete -f solution/05-no-class-BAD.yaml
```

### Step 5: `defaultBackend`

```bash
kubectl apply -f solution/06-default-backend.yaml
sleep 5
curl -s -H "Host: fallback.local" http://localhost:8080/api        # API
curl -s -H "Host: fallback.local" http://localhost:8080/anything   # ROOT
```

**The second matched no rule and went to `defaultBackend`** instead of returning
404. That is how you serve a maintenance page or a catch-all SPA.

```bash
kubectl delete -f solution/06-default-backend.yaml
```

### Step 6: What the backend sees about the client

```bash
kubectl logs -l app=root --tail=5 --prefix
curl -s -H "Host: paths.local" http://localhost:8080/ >/dev/null
kubectl logs -l app=root --tail=3
```

The nginx access log shows **the ingress controller's pod IP** as the client, and
the real address in `X-Forwarded-For`. **Through an Ingress, the client IP is a
header, not the socket** — the same trade-off as
[CKA 23](../23-service-networking/) C3, arrived at from the other direction.

```bash
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf | grep -m3 -i "x-forwarded-for"
```

### Step 7: The Gateway API — attachment and refusal

Install the CRDs and Envoy Gateway if Day 20 left them out:

```bash
kubectl get crd | grep -c gateway.networking.k8s.io
kubectl get gatewayclass
```

If empty, run Day 20's Step 7 install, then continue.

```bash
kubectl create namespace cka25-infra
kubectl apply -f solution/07-gateway-restricted.yaml
kubectl -n cka25-infra get gateway platform-gw
kubectl -n cka25-infra get gateway platform-gw -o jsonpath='{.status.conditions}' | tr ',' '\n' | grep -E 'type|status'
```

Two listeners, differing only in `allowedRoutes` (25.5). Attach a route to the
open one:

```bash
kubectl apply -f solution/08-httproute-allowed.yaml
sleep 5
kubectl get httproute route-open -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|reason'
```

```
"type":"Accepted"     "reason":"Accepted"
"type":"ResolvedRefs" "reason":"ResolvedRefs"
```

Now the one that will be refused:

```bash
kubectl apply -f solution/09-httproute-refused.yaml
sleep 5
kubectl get httproute route-refused
kubectl get httproute route-refused -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|reason|message'
```

```
"type":"Accepted"  "status":"False"  "reason":"NotAllowedByListeners"
```

**The object exists and is perfectly valid.** `kubectl get` shows it. It does
nothing, and **the reason is in `status`, written by the implementation** — which
is precisely what an Ingress cannot do (25.5).

Grant the namespace access and watch it flip:

```bash
kubectl label namespace cka25 gateway-access=true
sleep 10
kubectl get httproute route-refused -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|reason'
```

```
"type":"Accepted"  "status":"True"  "reason":"Accepted"
```

**One label on a namespace, and the platform team's policy admitted the route.**
Nothing about the HTTPRoute changed.

```bash
kubectl label namespace cka25 gateway-access-
```

### Step 8: Cross-namespace, and the grant that permits it

```bash
kubectl apply -f solution/13-data-namespace.yaml
kubectl rollout status deployment/data -n cka25-data --timeout=120s
kubectl apply -f solution/10-crossns-route-BAD.yaml
sleep 8
kubectl get httproute route-crossns -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|status|reason'
```

```
"type":"Accepted"      "status":"True"
"type":"ResolvedRefs"  "status":"False"  "reason":"RefNotPermitted"
```

**Two conditions telling two different stories.** The *listener* accepted the
route; the *backend reference* was refused. Reading both is the skill.

```bash
kubectl apply -f solution/11-referencegrant.yaml
sleep 8
kubectl get httproute route-crossns -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|status'
kubectl get referencegrant -n cka25-data
```

`ResolvedRefs` is now `True`. **The permission was created in `cka25-data`, by
that namespace's owner** — the route's author could not grant it to themselves
(25.6).

### Step 9: Filters instead of annotations

```bash
kubectl apply -f solution/12-filters.yaml
sleep 8
kubectl get httproute route-filters -o jsonpath='{.status.parents[0].conditions}' | tr '}' '\n' | grep -E 'type|status'
```

Find the Gateway's address and test it:

```bash
GWSVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=platform-gw -o name | head -1)
kubectl -n envoy-gateway-system port-forward "$GWSVC" 8888:80 >/dev/null 2>&1 &
PF=$!
sleep 3

curl -s -H "Host: open.local" http://localhost:8888/api/v1/users
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" -H "Host: open.local" http://localhost:8888/old/page
kill $PF 2>/dev/null
```

```
API-api-xxxx path=/v1/users
301 -> https://open.local/old/page
```

**The `URLRewrite` filter did what `rewrite-target: /$2` did**, and the
`RequestRedirect` filter did what `ssl-redirect` did — as **typed fields with
schema validation**, not strings in annotations (25.7).

Compare the two files side by side. That difference is the whole argument for
the Gateway API:

```bash
grep -A4 annotations solution/03-rewrite-correct.yaml
grep -A8 filters solution/12-filters.yaml
```

### Cleanup

```bash
kubectl delete namespace cka25 cka25-infra cka25-data --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Predict the routing

An Ingress for `shop.example.com` defines:

```
/                     Prefix   -> frontend
/api                  Prefix   -> api
/api/v2               Prefix   -> api-v2
/api/v2/checkout      Exact    -> checkout
/static               Exact    -> cdn
```

Give the backend for each request, and the rule that decided it:

1. `/` 2. `/products` 3. `/api/orders` 4. `/api/v2/orders`
5. `/api/v2/checkout` 6. `/api/v2/checkout/confirm` 7. `/static`
8. `/static/logo.png` 9. `/apiv2/orders`

Two of these commonly surprise people. Say which and why.

### C2 - Diagnose four Ingresses

For each, name the cause and the confirming command:

1. `ADDRESS` is empty and has been for an hour.
2. `ADDRESS` is populated; every request returns `404` from the default backend.
3. Requests return `503`.
4. The rewrite annotation is present and the backend still receives the full
   path.

### C3 - Two controllers

A cluster needs an **internal** ingress (private load balancer, internal DNS) and
an **external** one, both nginx.

1. What objects distinguish them, and what must be unique?
2. Write the two `IngressClass` objects.
3. How does an application team choose, and what happens if they choose neither?
4. Give one reason `is-default-class` is dangerous here.

### C4 - Translate to the Gateway API

Convert this to Gateway API objects, and say which team owns each:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: shop
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend: {service: {name: api, port: {number: 8080}}}
```

Then name one thing the Gateway API version can do that the Ingress cannot.

### C5 - The silent failure

A team reports their HTTPRoute "does nothing". `kubectl get httproute` shows it,
`kubectl describe` shows no events, and the Gateway is `Programmed=True`.

Give the exact command that will tell you why, list the four conditions you might
see and what each means, and explain why this situation is strictly better than
the Ingress equivalent.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the controller's backend list contains pod IPs rather than the ClusterIP;
path precedence resolves as 25.2 predicts for six paths; the correct rewrite
strips the prefix and the `Prefix`-typed one silently 404s; an Ingress naming a
non-existent class has no ADDRESS; and, if the Gateway API is installed, that an
HTTPRoute is refused by `allowedRoutes` and a cross-namespace backend is refused
without a ReferenceGrant.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# is anything going to pick this up?
kubectl get ingress -A            # empty ADDRESS == unclaimed
kubectl get ingressclass
kubectl describe ingress NAME | tail -20

# what did the controller actually generate?
CTRL=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl exec -n ingress-nginx $CTRL -- cat /etc/nginx/nginx.conf | grep -A20 "server_name HOST"
kubectl exec -n ingress-nginx $CTRL -- curl -s http://127.0.0.1:10246/configuration/backends

# create one quickly
kubectl create ingress web --class=nginx --rule="app.local/*=web:80"
kubectl create ingress web --class=nginx \
  --rule="app.local/api*=api:80" --rule="app.local/*=web:80"

# Gateway API -- status is where the answer is
kubectl get httproute NAME -o jsonpath='{.status.parents[*].conditions}' | jq
kubectl get gateway NAME -o jsonpath='{.status.listeners[*].conditions}' | jq
kubectl get gateway NAME -o jsonpath='{.status.listeners[*].attachedRoutes}{"\n"}'
kubectl get referencegrant -A
```

**Traps**

- **The backend Service is not in the data path.** The controller proxies to pod
  IPs, so `sessionAffinity` and `externalTrafficPolicy` on it do nothing.
- **`ClusterIP` is the right Service type for an Ingress backend.**
- **`Prefix` is element-wise**: `/api` does not match `/apiary`.
- **Longest match wins; `Exact` beats `Prefix` at equal length.** YAML order is
  irrelevant.
- **A regex path requires `pathType: ImplementationSpecific`.** With `Prefix` it
  silently never matches.
- **Empty `ADDRESS` = no controller adopted it.** Check `ingressClassName`
  against `kubectl get ingressclass`.
- **`ingressClassName` is the field**; the `kubernetes.io/ingress.class`
  annotation is deprecated.
- **Annotations are controller-specific** and do not port.
- **Through an Ingress, the client IP is `X-Forwarded-For`**, not the socket.
- **An HTTPRoute reports its refusal in `status.parents[].conditions`** —
  `Accepted` and `ResolvedRefs` are separate conditions with separate causes.
- **Cross-namespace `backendRefs` need a `ReferenceGrant`** in the *target*
  namespace.
- **Gateway API CRDs are not part of Kubernetes** and must be installed, along
  with an implementation.

---

**Previous:** [CKA 24 — DNS and CoreDNS](../24-dns-and-coredns/)
**Next:** [CKA 26 — Cluster Design and High Availability](../26-cluster-design-and-ha/)
