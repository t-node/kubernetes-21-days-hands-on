# CKA 07 solution

## Challenge answers

### C1 - Enforce a registry

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: allowed-registries}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  variables:
    - name: allPods
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
  validations:
    - expression: >-
        variables.allPods.all(c,
          c.image.startsWith('registry.internal.example.com/') ||
          c.image.startsWith('registry.k8s.io/'))
      message: "images must come from registry.internal.example.com or registry.k8s.io"
      reason: Forbidden
```

**Why a policy and not a webhook:** the rule is a pure function of the object.
Everything needed to decide is in `spec.containers[*].image`; there is no
external lookup, no mutation, and no state. A webhook would add a Deployment, a
Service, a certificate, a CA bundle and a `failurePolicy` cliff to reach the
same verdict.

`initContainers` and `ephemeralContainers` are optional fields, so `has()`
guards are required — a CEL expression that dereferences a missing field errors,
and under `failurePolicy: Fail` an erroring expression **rejects the request**.
That is the single most common mistake when writing these.

**When you would need a webhook instead:**
- the allow-list lives in an external system (a CMDB, an artifact registry API)
- you must *rewrite* the image reference to an internal mirror rather than
  reject it — policies cannot mutate
- the decision depends on the image's *contents* (a signature or SBOM lookup)

### C2 - Why is my pod different from my file?

```bash
# 1. Which built-in plugins are running at all?
kubectl -n kube-system exec kube-apiserver-controlplane -- kube-apiserver -h \
  | grep -A6 enable-admission-plugins
grep -E "enable-admission|disable-admission" /etc/kubernetes/manifests/kube-apiserver.yaml

# 2. Which webhooks intercept pods?
kubectl get mutatingwebhookconfiguration -o custom-columns=\
NAME:.metadata.name,SVC:.webhooks[*].clientConfig.service.name,RES:.webhooks[*].rules[*].resources

# 3. What did the user actually submit?
kubectl get deploy X -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | jq

# 4. Diff submitted against stored -- the delta IS the mutation
kubectl diff -f their-file.yaml
```

**How to attribute each change:**

- `imagePullPolicy: Always` with no such line in the file is the built-in
  **`AlwaysPullImages`** plugin — visible in the enable list from (1). (Note that
  `imagePullPolicy` also defaults to `Always` for an untagged or `:latest`
  image; check the tag before blaming a plugin.)
- `securityContext` appearing on a pod template is not a built-in behaviour, so
  it came from a **mutating webhook** — find it in (2) and read its Service and
  logs.
- The `last-applied-configuration` annotation from (3) is the ground truth of
  what was submitted, which is exactly what CKA 04 built.

Anything the admission chain injected is present in the live object but absent
from that annotation. **The annotation minus the live object is the mutation.**

### C3 - The unrecoverable cluster

The sequence:

1. A `ValidatingWebhookConfiguration` is created with `failurePolicy: Fail`,
   `rules` matching `pods` on `CREATE`, and **no `namespaceSelector`**.
2. The webhook's own pod dies — node reboot, image pull failure, OOM, a bad
   rollout.
3. The API server now cannot reach the webhook. `failurePolicy: Fail` means
   **every** pod CREATE is rejected cluster-wide.
4. The Deployment controller tries to recreate the webhook pod. That is a pod
   CREATE. It is rejected by the webhook that the pod would have been.

**Why restarting the pod does not work:** there is no pod to restart, and
creating one is precisely the operation that is blocked. The webhook has made
itself a prerequisite for its own existence. `kubectl delete pod` succeeds
(DELETE is not in the rules) but nothing replaces it. Nodes rebooting makes it
worse, never better.

**The escape, two commands:**

```bash
kubectl delete validatingwebhookconfiguration <name>
# and, if a mutating one is also implicated:
kubectl delete mutatingwebhookconfiguration <name>
```

Deleting the **configuration** — not the Deployment, not the Service — is what
stops the API server dialling. `DELETE` on a webhook configuration is itself not
intercepted, so this works even in the wedged state. Recreate the configuration
after the server is Ready.

**The two things that prevent it in the first place:**
- a `namespaceSelector` excluding `kube-system` and the webhook's own namespace
- `failurePolicy: Ignore` while you are still developing the webhook

### C4 - Order of operations

**The pod succeeds.** The mutating webhook runs first and stamps
`runAsUser: 1234`; the validating webhook then sees 1234, which is not below
1000, and allows it. The validator judges the *mutated* object, never the
submitted one.

**Can you swap them? No.** The ordering mutating-then-validating is built into
the API server's admission chain and is not configurable. There is no priority
field, no ordering annotation, and no way to express "validate first".

What *is* and *is not* under your control:

| | Configurable? |
|---|---|
| Mutating phase before validating phase | **no** — fixed |
| Order among several **mutating** webhooks | not directly; they are called in an unspecified order, and the chain **re-runs** if any of them changes the object (`reinvocationPolicy: IfNeeded`) |
| Order among several **validating** webhooks | irrelevant — they run in parallel and *any* rejection wins, so order cannot change the outcome |
| Order of built-in plugins relative to webhooks | **no** — built-ins run first; webhook controllers are the last stage |

The practical consequence: **a validating webhook must be written to judge the
final object, not the user's intent.** If you need to reject what the user
*wrote* rather than what admission produced, the mutating webhook has already
destroyed that information — the only surviving record is the
`last-applied-configuration` annotation, and only for `kubectl apply`.

`reinvocationPolicy: IfNeeded` is the escape hatch for mutating webhooks that
depend on each other: it asks the API server to call your webhook a second time
if a later mutator changed the object. It makes your webhook's own logic need to
be **idempotent** — running twice must give the same result as running once.

### C5 - Read a hostile configuration

**What it achieves:** every `CREATE` of a Secret, cluster-wide, is POSTed in
full to `collector.attacker.example`. The `AdmissionReview` body contains the
**entire object**, so `data` — the base64 Secret payload — leaves the cluster.
It is a complete, real-time exfiltration channel for every credential created
from this moment on, and it is not an exploit: it is the documented behaviour of
the feature.

Two further details make it worse:

- `apiGroups: ["*"]` / `apiVersions: ["*"]` catch everything, now and after
  upgrades.
- It is a **validating** webhook, so it never mutates and never patches.
  Nothing about any created object looks different. There is no artefact to
  find.

**Why `failurePolicy: Ignore` is the dangerous choice here:** it makes the
attack *invisible and durable*. With `Fail`, an unreachable collector would
break Secret creation loudly and somebody would investigate within minutes.
With `Ignore`, the cluster behaves perfectly whether the collector is up or
down — so nothing ever alerts, and the configuration survives indefinitely.
The usual reading (`Fail` is strict, `Ignore` is lenient) inverts once the
webhook's purpose is exfiltration rather than policy: **`Ignore` is what buys
the attacker silence.**

`sideEffects: None` is a further lie to the API server — it asserts that calling
this webhook changes nothing outside the request, which permits the API server
to call it during `--dry-run` too. Dry-run Secret creations get exfiltrated as
well.

**The RBAC rule that should have prevented it:**

```yaml
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
  verbs: ["create", "update", "patch", "delete"]
```

**Write access to webhook configurations is equivalent to cluster-admin**, and
should be treated as such. Anyone holding it can read every object the cluster
creates and reject or rewrite any of them. It belongs to platform administrators
and to nobody else — in particular, never to a namespace-scoped operator or a CI
service account, which is exactly how it usually leaks. Detect it with:

```bash
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -o custom-columns=NAME:.metadata.name,URL:.webhooks[*].clientConfig.url,SVC:.webhooks[*].clientConfig.service.name
```

**Any `url:` pointing outside the cluster deserves an explanation.**

---

## Files

| File | Purpose |
|---|---|
| `toggle-plugin.sh` | add/remove a plugin on the API server static pod manifest, with backup and readiness wait |
| `01-pvc-no-class.yaml` | PVC with no class -- shows `DefaultStorageClass` mutating |
| `02-webhook-deployment.yaml` | webhook server Deployment + Service (443 -> 8443) |
| `03-webhook-configuration.yaml` | Mutating + Validating configurations, `CA_BUNDLE_PLACEHOLDER` filled in at deploy time |
| `04-pod-with-defaults.yaml` | no securityContext -- gets one injected |
| `05-pod-with-override.yaml` | `runAsNonRoot: false` -- left alone |
| `06-pod-with-conflict-BAD.yaml` | contradictory -- rejected at admission |
| `07-validating-admission-policy.yaml` | CEL policy + Deny binding + Warn binding |
| `08-policy-test-pods.yaml` | one compliant pod and two violations |
| `webhook/server.py` | the admission server: stdlib Python, AdmissionReview v1 |
| `webhook/deploy-webhook.sh` | certificates, secret, configmap, deploy, configure |
| `verify.sh` | checks every claim in Part 4 |

> **Do not `kubectl apply -f solution/`.** This directory holds
> `06-pod-with-conflict-BAD.yaml` (meant to be rejected) and
> `03-webhook-configuration.yaml` (contains a placeholder, applied by the
> script). Follow the lab steps.

---

## Notes on `server.py`

It is deliberately dependency-free — `http.server` and `ssl` from the standard
library — so it runs on the stock `python:3.12-alpine` image straight from a
ConfigMap. Nothing to build, nothing to `kind load`.

Three details that are not obvious and that a real webhook must also get right:

1. **Echo the `uid`.** `response.uid` must equal `request.uid` or the API server
   discards the reply as unmatched.
2. **Base64 the patch.** `response.patch` is a base64-encoded JSON Patch array,
   and `patchType` must say `JSONPatch`.
3. **Return `allowed: true` for anything you do not care about.** A webhook that
   errors, times out or returns garbage is treated according to
   `failurePolicy` — under `Fail`, that is a cluster-wide outage. Defaulting to
   allow is what keeps a buggy webhook from becoming an incident.

The mutation logic only ever *adds* fields that are absent. That is the rule for
mutating webhooks generally: fill gaps, never overrule an explicit decision. A
mutator that rewrites what the user wrote produces objects nobody can explain
and manifests that no longer describe reality.

**Production note:** managing the CA bundle by hand, as `deploy-webhook.sh`
does, does not survive certificate rotation. Real deployments use cert-manager
with a `caBundle` injection annotation, or the `CertificateSigningRequest` API
from [CKA 15](../../15-certificates-api-and-authorization/). The manual path is
here because it makes every moving part visible exactly once.
