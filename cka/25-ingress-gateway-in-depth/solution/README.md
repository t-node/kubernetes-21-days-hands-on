# CKA 25 solution

## Challenge answers

### C1 - Predict the routing

| # | Request | Backend | Rule that decided it |
|---|---|---|---|
| 1 | `/` | **frontend** | `/` Prefix -- the only match |
| 2 | `/products` | **frontend** | `/` Prefix; nothing longer matches |
| 3 | `/api/orders` | **api** | `/api` Prefix, longest match |
| 4 | `/api/v2/orders` | **api-v2** | `/api/v2` Prefix beats `/api` -- longer |
| 5 | `/api/v2/checkout` | **checkout** | Exact wins at equal length |
| 6 | `/api/v2/checkout/confirm` | **api-v2** | Exact did not match; `/api/v2` Prefix did |
| 7 | `/static` | **cdn** | Exact matches |
| 8 | `/static/logo.png` | **frontend** | Exact did NOT match; falls back to `/` |
| 9 | `/apiv2/orders` | **frontend** | element-wise: `/api` does not match `/apiv2` |

**The two that surprise people are 6 and 8.**

**6** — `/api/v2/checkout/confirm` looks like it belongs to the checkout service.
It does not, because `Exact` means *the whole path or nothing*. Adding one path
element takes it to a different backend. This bites teams who define an `Exact`
rule for a route and then add a sub-path.

**8** — `/static/logo.png` is the one that breaks production. Someone writes
`pathType: Exact` for `/static` intending "the static area", and every actual
asset falls through to the frontend, which returns `index.html` with a 200 and a
`text/html` content type. **The browser fails to load images and CSS with no
error anywhere in Kubernetes.** `Prefix` is nearly always what was meant.

**9** is the element-wise rule (25.2): `/apiv2` shares a string prefix with
`/api` but not a path-element prefix, so it does not match.

### C2 - Diagnose four Ingresses

**1. `ADDRESS` empty for an hour**

**No controller adopted it** (25.4).

```bash
kubectl get ingress NAME -o jsonpath='{.spec.ingressClassName}{"\n"}'
kubectl get ingressclass
kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

Three causes: a typo in `ingressClassName`; no class named and no default class;
or the controller is not running at all. **Note there is no event and no error** —
the empty column is the only signal, which is why it goes unnoticed for an hour.

Check the controller too:

```bash
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx <controller> | grep -i "ingress NAME"
```

**2. `ADDRESS` populated, everything 404s**

The controller adopted it and **no `location` matched the request**. The Ingress
is claimed; the rules are wrong.

```bash
kubectl describe ingress NAME
CTRL=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl exec -n ingress-nginx $CTRL -- cat /etc/nginx/nginx.conf | grep -A20 "server_name HOST"
curl -v -H "Host: HOST" http://<addr>/path
```

Most likely: **the `Host` header does not match `spec.rules[].host`** (a request
to the IP without a `Host` header matches no host-scoped rule), or a **regex path
with `pathType: Prefix`** (25.3, and Step 3 of the lab).

Reading the generated `nginx.conf` distinguishes them in one command: if there is
no `server_name` for your host, it is the host; if there is, look at the
`location` blocks.

**3. `503`**

**The backend has no endpoints.** The controller matched a rule and had nowhere
to send the request.

```bash
kubectl get endpoints <backend-service>
kubectl get pods -l <selector> -o wide           # are they Ready?
kubectl get svc <backend-service> -o yaml | grep -A3 -E "selector|targetPort"
```

Same three causes as any endpoint-less Service
([CKA 23](../../23-service-networking/)): the selector matches nothing, the pods
are not `Ready`, or `targetPort` does not match the container's port.

**404 versus 503 is the useful split:** 404 means routing did not match, 503
means routing matched and the backend is unavailable.

**4. The rewrite is ignored**

Almost always **`pathType` is not `ImplementationSpecific`** (25.3), so the regex
path never matched and the request was served by some other rule that has no
rewrite.

```bash
kubectl get ingress NAME -o jsonpath='{.spec.rules[0].http.paths[0].pathType}{"\n"}'
kubectl get ingress NAME -o jsonpath='{.metadata.annotations}{"\n"}'
```

Two other causes worth checking: **the annotation prefix is wrong** for the
controller in use (`nginx.ingress.kubernetes.io/` for ingress-nginx,
`traefik.ingress.kubernetes.io/` for Traefik — an annotation the controller does
not recognise is silently ignored), and **`use-regex: "true"` is missing** on
older ingress-nginx versions.

### C3 - Two controllers

**1. What distinguishes them.**

Each controller deployment is configured with an `--ingress-class` (or
`--controller-class`) it watches, and each has its own `IngressClass` object
naming it. What must be unique:

- **the `IngressClass` name** — that is what applications write
- **the controller's own Service** and its load balancer / node ports
- **the `--election-id`** on each controller deployment, or two controllers
  contend for the same leader lease and one of them stops working

The `spec.controller` string may be **the same** (`k8s.io/ingress-nginx` for
both) — it identifies the implementation, not the instance. Differentiation is by
`IngressClass` name plus each deployment's `--ingress-class` flag.

**2. The two objects:**

```yaml
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx-external
spec:
  controller: k8s.io/ingress-nginx
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx-internal
spec:
  controller: k8s.io/ingress-nginx
```

Neither marked default — see 4.

**3. How a team chooses:**

```yaml
spec:
  ingressClassName: nginx-internal
```

**If they name neither and no default class exists, the Ingress is adopted by
nobody** and sits with an empty `ADDRESS` (25.4). That is a *good* failure: loud
in the one place people look, and impossible to mistake for working.

**4. Why `is-default-class` is dangerous here.**

Because a forgotten `ingressClassName` silently gets the default — and if the
default is `nginx-external`, **an application intended to be internal is
published to the internet** by an omission rather than a decision.

The failure is invisible: the Ingress works, the ADDRESS populates, requests
succeed. Nothing indicates that the wrong controller adopted it.

**With two controllers and different exposure levels, set no default at all.**
Force every Ingress to state its intent. The cost is an occasional empty ADDRESS
column; the alternative cost is an unintended public endpoint.

If you must have a default, make it the **internal** one, so the failure mode is
"not reachable" rather than "reachable by everyone".

### C4 - Translate to the Gateway API

```yaml
---
# OWNED BY THE PLATFORM TEAM -- infrastructure, TLS, and who may attach
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gw
  namespace: infra
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "shop.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: shop-tls
            namespace: infra         # the cert lives with the Gateway
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: {gateway-access: "true"}
    - name: http
      port: 80
      protocol: HTTP
      hostname: "shop.example.com"
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: {gateway-access: "true"}
---
# OWNED BY THE PLATFORM TEAM -- the ssl-redirect, once, for everyone
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: infra
spec:
  parentRefs:
    - {name: public-gw, sectionName: http}
  hostnames: ["shop.example.com"]
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
# OWNED BY THE APPLICATION TEAM -- routing only
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-api
  namespace: shop
spec:
  parentRefs:
    - name: public-gw
      namespace: infra
      sectionName: https
  hostnames: ["shop.example.com"]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /api}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - {name: api, port: 8080}
```

Plus `kubectl label namespace shop gateway-access=true`.

**How each piece translates:**

| Ingress | Gateway API | Owner |
|---|---|---|
| `ingressClassName: nginx` | `gatewayClassName` on the **Gateway** | platform |
| `tls: {secretName: shop-tls}` | listener `certificateRefs` | platform |
| `ssl-redirect: "true"` | a `RequestRedirect` filter on the HTTP listener | platform |
| `rewrite-target: /$2` + regex path | `URLRewrite` with `ReplacePrefixMatch` | app |
| `rules[].host` | `hostnames` on the route and the listener | both |
| `backend.service` | `backendRefs` | app |

**Note what moved.** TLS and the HTTPS redirect were application-team concerns in
the Ingress -- every team had to remember the annotation and reference the
certificate. In the Gateway API they belong to the platform, configured once. The
application team's object now contains **only routing**, which is the entire
point of the split (25.5).

Also note the regex disappeared. `ReplacePrefixMatch` expresses "strip /api"
directly, so there are no capture groups and no `ImplementationSpecific` trap.

**One thing the Gateway API version can do that the Ingress cannot:**

**Weighted traffic splitting.**

```yaml
      backendRefs:
        - {name: api, port: 8080, weight: 90}
        - {name: api-canary, port: 8080, weight: 10}
```

Ingress has no field for it. ingress-nginx offers canary annotations that require
a *second Ingress object* shadowing the first, and that mechanism works on one
controller. Here it is one list with weights, portable everywhere.

Two more worth naming: **cross-namespace backends** with a `ReferenceGrant`
(25.6), which Ingress cannot express at all, and **`allowedRoutes`**, which lets
the platform team constrain who may claim a hostname.

### C5 - The silent failure

**The command:**

```bash
kubectl get httproute NAME -n NS -o jsonpath='{.status.parents}' | jq
```

**`status.parents` answers nearly every "my route does nothing" question**
(25.5). It holds one entry per `parentRef`, each with its own conditions — so a
route attached to two Gateways can be accepted by one and refused by the other,
and you see both.

**The conditions you might see:**

| `type` | `status` | `reason` | Means |
|---|---|---|---|
| `Accepted` | True | `Accepted` | the listener took the route |
| `Accepted` | **False** | `NotAllowedByListeners` | **`allowedRoutes` refused it** -- the namespace is not permitted (25.5) |
| `Accepted` | **False** | `NoMatchingListenerHostname` | the route's `hostnames` do not intersect the listener's |
| `Accepted` | **False** | `NoMatchingParent` | the `parentRef` names a Gateway or `sectionName` that does not exist |
| `ResolvedRefs` | **False** | `RefNotPermitted` | a cross-namespace `backendRef` with **no ReferenceGrant** (25.6) |
| `ResolvedRefs` | **False** | `BackendNotFound` | the Service in `backendRefs` does not exist |

**`Accepted` and `ResolvedRefs` are independent.** A route can be accepted by the
listener and still fail on its backend — exactly the state the lab's
`route-crossns` produces — so reading one condition gives you half the story.

Check the Gateway's own view too, which counts what attached:

```bash
kubectl get gateway NAME -n NS \
  -o jsonpath='{range .status.listeners[*]}{.name}{": "}{.attachedRoutes}{"\n"}{end}'
```

`attachedRoutes: 0` on the listener you expected confirms it from the other side.

**Why this is strictly better than the Ingress equivalent.**

An Ingress in the same situation gives you **nothing**. If no controller adopts
it, `ADDRESS` is empty with no event, no condition and no message — you compare
`ingressClassName` against `kubectl get ingressclass` by eye (C2.1). If a
controller adopts it and the rules are wrong, you get a 404 and must read the
controller's generated configuration to find out why (C2.2).

**The Gateway API made the implementation's decision part of the API.** An
implementation is *required* to write back why it accepted or refused, as a
structured, typed condition — so the failure is machine-readable, visible in
`kubectl get -o yaml`, and can be alerted on:

```bash
kubectl get httproute -A -o json | jq -r '.items[] |
  select(.status.parents[]?.conditions[]? |
         select(.type=="Accepted" and .status=="False")) |
  "\(.metadata.namespace)/\(.metadata.name)"'
```

**That query is not expressible for Ingress**, because there is nothing to query.
It is the most practical difference between the two APIs day to day, and it
matters more than the feature list.

---

## Files

| File | Purpose |
|---|---|
| `01-backends.yaml` | three backends reporting which answered and what path they received |
| `02-pathtype-precedence.yaml` | four overlapping paths in deliberately unhelpful YAML order |
| `03-rewrite-correct.yaml` | regex path + `ImplementationSpecific` + `rewrite-target: /$2` |
| `04-rewrite-BAD.yaml` | the same thing with `pathType: Prefix` -- silently 404s |
| `05-no-class-BAD.yaml` | names a non-existent IngressClass -- empty ADDRESS forever |
| `06-default-backend.yaml` | `defaultBackend` as a catch-all |
| `07-gateway-restricted.yaml` | two listeners differing only in `allowedRoutes` |
| `08-httproute-allowed.yaml` | attaches to the open listener |
| `09-httproute-refused.yaml` | refused -- a valid object with `Accepted=False` |
| `10-crossns-route-BAD.yaml` | cross-namespace backend, no grant -- `RefNotPermitted` |
| `11-referencegrant.yaml` | the grant, in the **target** namespace |
| `12-filters.yaml` | `URLRewrite`, `RequestHeaderModifier`, `RequestRedirect` |
| `13-data-namespace.yaml` | the other team's namespace and Service |
| `verify.sh` | checks every claim in Part 4 |

> **Do not `kubectl apply -f solution/`.** Four files are meant to fail, and
> `11-referencegrant.yaml` must be applied *after* you have seen `10` refused.

---

## Why Step 1 comes first

Reading the generated `nginx.conf` before anything else is deliberate. Every
subsequent failure in this assignment — the `Prefix`-typed regex, the unclaimed
Ingress, a host that does not match — is **invisible from `kubectl`** and obvious
in the generated configuration.

That is the general lesson: **an Ingress is a request; the controller's config is
what happened.** When they disagree, `kubectl describe ingress` will not tell
you, because the object is exactly as you wrote it.

The equivalent for the Gateway API is `status.parents` (C5), and the fact that
you do *not* have to exec into a pod to read it is the improvement.

## On the ingress-nginx internal endpoint

```bash
kubectl exec -n ingress-nginx $CTRL -- curl -s http://127.0.0.1:10246/configuration/backends
```

Port 10246 is the controller's internal status endpoint, not a documented stable
API. It is the fastest way to see resolved backends and it may move between
versions — if it returns nothing, fall back to reading `nginx.conf`, where the
same information appears as `upstream` blocks or in the Lua configuration.

Neither is something to script against. Both are the right thing to look at when
a route behaves in a way the Ingress object does not explain.
