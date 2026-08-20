# Day 20 solution

## Install the controller first

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
```

The **kind provider** variant is required: it runs the controller with
`hostPort: 80/443` on the `ingress-ready` node instead of waiting for a cloud
LoadBalancer that kind cannot provide.

## Route DevBoard through it

```bash
kubectl apply -f 01-ingress-basic.yaml
sleep 10
curl -s -H "Host: devboard.local" http://localhost:8080/api/tasks | head -c 200
```

`localhost:8080` maps to the node's port 80 via `cluster/kind-config.yaml`.

## Files

| File | Shows |
|---|---|
| `01-ingress-basic.yaml` | path routing **with** the `/api` rewrite |
| `02-ingress-no-rewrite.yaml` | the same **without** it — 404s everywhere |
| `03-ingress-hosts.yaml` | host-based routing, no rewrite needed |
| `04-ingress-tls.yaml` | TLS termination + HTTP→HTTPS redirect |
| `05-gatewayclass-note.yaml` | who owns which Gateway API object |
| `06-gateway.yaml` | the **operator's** object: listeners and TLS |
| `07-httproute.yaml` | the **developer's** object — compare with `01` |
| `08-httproute-canary.yaml` | weighted splitting + header matching |
| `BAD-01` … `BAD-04` | the four classic Ingress failures |

## The comparison that matters

Open `01-ingress-basic.yaml` and `07-httproute.yaml` side by side.

```
nginx.ingress.kubernetes.io/rewrite-target: /$2     <- an annotation, nginx only
path: /api(/|$)(.*)                                 <- regex capture groups

                       versus

filters:
  - type: URLRewrite                                <- a typed API field
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
```

Same behaviour. One is vendor-specific and unvalidated; the other is portable,
schema-checked, and works identically on Envoy Gateway, Istio, Contour, Cilium
or a cloud implementation.

That is the whole argument for the Gateway API in one diff.
