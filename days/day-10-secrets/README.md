# Day 10 — Secrets

**Time:** 75-90 minutes
**Prerequisites:** Day 09

Secrets look like ConfigMaps with base64 on top. Today you learn what they
actually protect you from, what they emphatically do not — and you solve a real
design problem: the DevBoard backend wants a single connection string that
contains the password.

---

## Part 1 - Concepts

### 10.1 The honest starting point

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: devboard-secrets
type: Opaque
data:
  POSTGRES_PASSWORD: ZGV2Ym9hcmQ=      # base64
```

Anyone can read that:

```bash
echo ZGV2Ym9hcmQ= | base64 -d
# devboard
```

**base64 is encoding, not encryption.** It exists so binary data (TLS keys,
certificates) can live in a YAML field, not to hide anything. Say that in an
interview and you have already beaten most candidates.

So why bother? Because a Secret is a **distinct object kind**, and that
distinction is the hook every real control hangs off:

| Property | ConfigMap | Secret |
|---|---|---|
| Separately targetable by RBAC | yes | **yes — and denied separately** |
| Encryption at rest in etcd | no | **yes, with an EncryptionConfiguration** |
| Written to node disk | yes | **no — tmpfs (RAM) only** |
| Value shown by `kubectl describe` | yes | **no (byte counts)** |
| Distributed to nodes | any node | **only nodes running a pod that needs it** |
| Targeted by audit and admission policy | rarely | **routinely** |

Whether a Secret is *secure* depends entirely on what you hang on it.

### 10.2 What Secrets do NOT protect against

1. **Anyone with `get secret` in the namespace reads them in plaintext.**
2. **Anyone who can `exec` into the pod reads them** — they are env vars or files.
3. **Anyone who can create a pod in the namespace reads them** — mount the
   Secret in a pod you control and `cat` it.
4. **Not encrypted in etcd by default.** Cluster-admin plus etcd access equals
   every secret.
5. **They end up in git** if you commit the manifest. By a wide margin the most
   common real-world leak.

### 10.3 How real teams solve it

| Approach | How | Trade-off |
|---|---|---|
| **External Secrets Operator** | syncs from AWS Secrets Manager / Vault / Key Vault into K8s Secrets | needs an operator; secrets still reach etcd |
| **Sealed Secrets** | encrypt with a cluster public key; ciphertext is safe to commit | cluster-specific; manual key rotation |
| **SOPS + age/KMS** | values encrypted in git, decrypted at deploy | good GitOps fit; pipeline tooling |
| **Vault Agent injector** | sidecar injects into the pod; no K8s Secret ever exists | most secure, most overhead |
| **Cloud workload identity** | the pod assumes an IAM role; no static credential exists | **the best answer where available** |

"There is no secret to steal" beats "the secret is well protected."

### 10.4 Today's real problem: the DSN contains the password

The Go backend reads **one** variable:

```
POSTGRES_URL=postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable
                        ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^ ^^^^^^^^
                        user     PASSWORD host     port database
```

Everything except the password is ordinary configuration. Three options:

**Option A — put the whole URL in a Secret.**
Simple, and very common. The cost: host, port, database and user are now
duplicated between the Secret and the ConfigMap, or missing from the ConfigMap
entirely, so changing the database hostname means editing a Secret. Config drift
follows.

**Option B — assemble it in the pod spec with `$(VAR)` interpolation.**

```yaml
env:
  - name: POSTGRES_USER          # from the ConfigMap
    valueFrom:
      configMapKeyRef: { name: devboard-config, key: POSTGRES_USER }
  - name: POSTGRES_PASSWORD      # from the Secret
    valueFrom:
      secretKeyRef: { name: devboard-secrets, key: POSTGRES_PASSWORD }
  - name: POSTGRES_HOST
    valueFrom:
      configMapKeyRef: { name: devboard-config, key: POSTGRES_HOST }
  # ...then compose the DSN from the pieces:
  - name: POSTGRES_URL
    value: "postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=$(POSTGRES_SSLMODE)"
```

Kubernetes expands `$(VAR)` against other environment variables **defined
earlier in the same container's `env` list**. The password stays in the Secret,
every other part stays in the ConfigMap, and nothing is duplicated.

**This course uses Option B.** It is the more instructive answer and it is real
practice — you will see it in Helm charts constantly.

Rules for `$(VAR)`:

- The referenced variable must be defined **earlier in the same `env` list**.
  Variables from `envFrom` are **not** reliably available for interpolation —
  define what you interpolate explicitly.
- An unresolvable `$(FOO)` is left **literally** in the value. No error. Your
  app then tries to connect to a host called `$(POSTGRES_HOST)`, which is a
  wonderfully confusing failure. You will do this deliberately in Break It.
- Escape a literal `$` as `$$`.

**Option C — let the app read a password file.** Cleanest where supported (the
`_FILE` convention in many official images), but the Go backend does not, so it
is not available here.

### 10.5 A DSN caveat that bites in production

If the password contains `@`, `/`, `:`, `?` or `#`, it **must be URL-encoded**
before going into a connection string. `p@ss/word` becomes `p%40ss%2Fword`.
Composing DSNs by concatenation, as above, does not encode for you. Either
constrain generated passwords to URL-safe characters, or have the app take
separate parameters instead of a DSN. This is a real outage cause.

### 10.6 Secret types

`type` is not decoration — Kubernetes validates required keys.

| Type | Required keys | For |
|---|---|---|
| `Opaque` | none | the default |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `imagePullSecrets` |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | Ingress TLS (Day 20) |
| `kubernetes.io/basic-auth` | `username`, `password` | basic auth |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | git over SSH |

### 10.7 `data` vs `stringData`

```yaml
data:
  POSTGRES_PASSWORD: ZGV2Ym9hcmQ=     # you base64-encode
stringData:
  POSTGRES_PASSWORD: devboard          # Kubernetes encodes for you
```

`stringData` is **write-only**: converted into `data` on the way in, never shown
when you read the object back. Use it in hand-written manifests — it removes a
whole class of encoding bugs, including the classic `echo` trailing-newline one.

### 10.8 env var vs volume mount, for secrets

| | env var | volume mount |
|---|---|---|
| Visible in `/proc/<pid>/environ` | **yes** | no |
| Leaks into crash dumps / env logging | **yes** | no |
| Rotates without a restart | **no** | yes (~60 s) |
| Stored on the node | container memory | **tmpfs (RAM)** |

**Volume mounts are the safer choice.** Env vars remain very common because they
are simpler and many apps — including this one — only support them. If you use
env vars, make sure your app never logs its own environment at startup. A
startling number do.

### 10.9 ServiceAccount tokens changed — know this

Every pod gets a token at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. Since Kubernetes 1.24
these are **projected, short-lived, audience-bound** tokens issued by the
kubelet, *not* long-lived Secret objects; creating a ServiceAccount no longer
auto-creates a token Secret.

If a pod never calls the Kubernetes API — like all three DevBoard tiers — turn
the mount off:

```yaml
spec:
  automountServiceAccountToken: false
```

Free hardening, and a good thing to raise on Day 19.

---

## Part 2 - Hands-on lab

### Step 1: base64 is not a lock

```bash
echo -n 'devboard' | base64      # ZGV2Ym9hcmQ=
echo 'ZGV2Ym9hcmQ=' | base64 -d  # devboard
```

**Use `echo -n`.** Without `-n`, `echo` appends a newline that gets encoded into
the secret, and Postgres rejects the password with no useful error:

```bash
echo    'devboard' | base64      # ZGV2Ym9hcmQK   <- 9 bytes, trailing \n
echo -n 'devboard' | base64      # ZGV2Ym9hcmQ=   <- 8 bytes, correct
```

PowerShell:

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("devboard"))
```

### Step 2: Create the Secret

```bash
kubectl apply -f solution/01-secret.yaml
kubectl get secret devboard-secrets -n devboard
kubectl describe secret devboard-secrets -n devboard
```

```
Data
====
POSTGRES_PASSWORD:  8 bytes
```

`describe` shows byte counts, never values — a guard against screenshots and
shoulder-surfing. A thin one:

```bash
kubectl get secret devboard-secrets -n devboard \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
# devboard
```

There is the password. **RBAC (Day 19) is the actual control.** Note also that
`stringData` is gone from the output — it was converted to `data` on write.

### Step 3: Assemble POSTGRES_URL from the pieces

This is today's main exercise. Read `solution/02-backend-deployment.yaml`
carefully, then apply it:

```bash
kubectl apply -f ../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f solution/02-backend-deployment.yaml
kubectl rollout status deployment/backend -n devboard --timeout=60s || true
```

The pods still CrashLoop — no Postgres until tomorrow — but you can read the
composed value off the object without a running pod:

```bash
kubectl get deploy backend -n devboard -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | python -m json.tool 2>/dev/null || \
kubectl get deploy backend -n devboard -o yaml | sed -n '/env:/,/livenessProbe/p'
```

And once Postgres exists (Day 11) you will see the fully expanded value inside
the container:

```bash
kubectl exec -n devboard deploy/backend -- env | grep POSTGRES_URL
# POSTGRES_URL=postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable
```

**Kubernetes did the interpolation, not your shell and not the app.** The
password came from the Secret; every other component came from the ConfigMap;
neither duplicates the other.

To see it right now without Postgres, use a throwaway pod with the same env
block:

```bash
kubectl apply -f solution/03-dsn-demo-pod.yaml
kubectl wait --for=condition=Ready pod/dsn-demo -n devboard --timeout=60s
kubectl logs dsn-demo -n devboard
kubectl delete pod dsn-demo -n devboard
```

### Step 4: Consume a Secret as a volume, and see tmpfs

```bash
kubectl apply -f solution/04-backend-deployment-secret-volume.yaml
kubectl apply -f solution/03-dsn-demo-pod.yaml
kubectl wait --for=condition=Ready pod/dsn-demo -n devboard --timeout=60s

kubectl exec -n devboard dsn-demo -- ls -la /etc/secrets
kubectl exec -n devboard dsn-demo -- cat /etc/secrets/POSTGRES_PASSWORD; echo
kubectl exec -n devboard dsn-demo -- df -h /etc/secrets
```

```
Filesystem  Size  Used Avail Use% Mounted on
tmpfs       3.9G  4.0K  3.9G   1% /etc/secrets
```

**tmpfs — RAM, not disk.** The secret is never written to the node's filesystem,
so it cannot be recovered from a stolen disk and it vanishes with the pod.

Then show the env-var leak path:

```bash
kubectl exec -n devboard dsn-demo -- sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep PASS'
kubectl delete pod dsn-demo -n devboard
```

Anything running in that container — including a compromised dependency — reads
it. That is the argument for volume mounts, and the reason the DevBoard backend
(env-var only) is a slightly weaker design than it could be.

### Step 5: A TLS secret (you need this on Day 20)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=devboard.local/O=devboard"

kubectl create secret tls devboard-tls -n devboard --cert=tls.crt --key=tls.key
kubectl get secret devboard-tls -n devboard        # TYPE kubernetes.io/tls, DATA 2
rm tls.key tls.crt
```

### Step 6: A registry pull secret

```bash
kubectl create secret docker-registry regcred -n devboard \
  --docker-server=ghcr.io --docker-username=myuser \
  --docker-password=ghp_faketoken --docker-email=me@example.com

kubectl get secret regcred -n devboard \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

Used as `spec.imagePullSecrets: [{name: regcred}]`, or attached to the
namespace's default ServiceAccount so every pod inherits it:

```bash
kubectl patch serviceaccount default -n devboard \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
kubectl patch serviceaccount default -n devboard \
  -p '{"imagePullSecrets":null}'                   # undo
```

### Step 7: See how exposed a Secret really is

```bash
# 1. read it directly
kubectl get secret devboard-secrets -n devboard \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

# 2. mount it into a pod you create
kubectl run stealer -n devboard --image=busybox:1.36 --restart=Never --rm -i \
  --overrides='{"spec":{"volumes":[{"name":"s","secret":{"secretName":"devboard-secrets"}}],"containers":[{"name":"stealer","image":"busybox:1.36","command":["cat","/s/POSTGRES_PASSWORD"],"volumeMounts":[{"name":"s","mountPath":"/s"}]}]}}'

# 3. exec into a pod that already has it
kubectl exec -n devboard deploy/backend -- env | grep PASSWORD
```

Three trivial paths. The conclusion is not "Secrets are useless" — it is that
**the security of a Secret is exactly the security of the RBAC around it.**
Day 19 is where you lock this down.

---

## Validate

```bash
kubectl apply -f ../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f solution/01-secret.yaml
kubectl apply -f solution/02-backend-deployment.yaml

kubectl get secret devboard-secrets -n devboard -o jsonpath='{.type}{"\n"}'   # Opaque

# the DSN is composed from parts, not hardcoded
kubectl get deploy backend -n devboard -o yaml | grep -A1 "name: POSTGRES_URL"
# value: postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):...

# and it interpolates correctly at runtime
kubectl apply -f solution/03-dsn-demo-pod.yaml
kubectl wait --for=condition=Ready pod/dsn-demo -n devboard --timeout=60s
kubectl logs dsn-demo -n devboard | grep POSTGRES_URL
kubectl delete pod dsn-demo -n devboard
```

Ready for Day 11 when you can:

1. Explain in one sentence why base64 is not security.
2. List three ways someone with namespace access reads a Secret.
3. Explain `$(VAR)` interpolation, including what happens when it fails.
4. Name two production approaches that avoid credentials in etcd.

---

## Break it

**A. A typo in an interpolated variable name.**

The most instructive failure of the day.

```bash
kubectl set env deployment/backend -n devboard \
  POSTGRES_URL='postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOSTNAME):5432/$(POSTGRES_DB)?sslmode=disable'

kubectl apply -f solution/03-dsn-demo-pod-broken.yaml
kubectl wait --for=condition=Ready pod/dsn-demo-broken -n devboard --timeout=60s
kubectl logs dsn-demo-broken -n devboard
```

```
POSTGRES_URL=postgres://devboard:devboard@$(POSTGRES_HOSTNAME):5432/devboard?sslmode=disable
                                          ^^^^^^^^^^^^^^^^^^^^ left literal
```

**No error. No warning.** `POSTGRES_HOSTNAME` does not exist, so Kubernetes
leaves the token verbatim, and your app tries to resolve a hostname called
`$(POSTGRES_HOSTNAME)`. The eventual error is a DNS failure that names a string
you never expected to see.

Remember the shape of this. It costs people hours.

```bash
kubectl delete pod dsn-demo-broken -n devboard
kubectl apply -f solution/02-backend-deployment.yaml
```

**B. The trailing-newline classic.**

```bash
kubectl create secret generic newline-bug -n devboard \
  --from-literal=PASSWORD="$(echo 'devboard')"

kubectl get secret newline-bug -n devboard \
  -o jsonpath='{.data.PASSWORD}' | base64 -d | xxd | tail -1
# ends in 0a  <- the newline is part of the password
kubectl delete secret newline-bug -n devboard
```

Postgres will say "password authentication failed" while the value *looks*
correct in every log you check.

**C. Invalid base64 in `data`.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bad-b64
  namespace: devboard
type: Opaque
data:
  PASSWORD: this-is-not-base64!!
EOF
# error: illegal base64 data at input byte 4
```

Use `stringData` and stop thinking about it.

**D. Wrong type for the required keys.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bad-tls
  namespace: devboard
type: kubernetes.io/tls
stringData:
  foo: bar
EOF
# Required value: must contain "tls.crt" and "tls.key"
```

**E. Reference a missing Secret.**

```bash
kubectl patch deployment backend -n devboard --type=json -p \
'[{"op":"add","path":"/spec/template/spec/containers/0/envFrom/-","value":{"secretRef":{"name":"does-not-exist"}}}]'

kubectl get pods -n devboard -l app=backend       # CreateContainerConfigError
kubectl rollout undo deployment/backend -n devboard
```

**F. A password with URL-special characters.**

```bash
kubectl patch secret devboard-secrets -n devboard \
  -p '{"stringData":{"POSTGRES_PASSWORD":"p@ss/word"}}'

kubectl apply -f solution/03-dsn-demo-pod.yaml
kubectl wait --for=condition=Ready pod/dsn-demo -n devboard --timeout=60s
kubectl logs dsn-demo -n devboard | grep POSTGRES_URL
```

```
postgres://devboard:p@ss/word@postgres:5432/devboard?sslmode=disable
                     ^ the parser now sees the host as "ss"
```

Section 10.5, made concrete. The DSN is now unparseable. Restore:

```bash
kubectl delete pod dsn-demo -n devboard
kubectl apply -f solution/01-secret.yaml
```

---

## Interview questions

<details>
<summary><b>1. Are Kubernetes Secrets secure?</b></summary>

Not by themselves. Values are base64-encoded, which is encoding not encryption,
and by default they sit unencrypted in etcd. Anyone with get on secrets in the
namespace, anyone who can exec into a pod, and anyone who can create a pod there
can read them. What a Secret gives you is a distinct object kind that RBAC,
encryption-at-rest, audit policy and admission control can target - the security
comes from what you configure on top of it.
</details>

<details>
<summary><b>2. How do you actually secure secrets in production?</b></summary>

Layered. Tight RBAC so almost nobody has get on secrets. An
EncryptionConfiguration with a KMS provider so etcd contents are encrypted.
Prefer workload identity - IRSA on EKS, Workload Identity on GKE - so no static
credential exists at all. Where one is unavoidable, source it from an external
store via External Secrets or the Vault injector, keep only ciphertext in git
via Sealed Secrets or SOPS, mount as files rather than env vars, and rotate
automatically.
</details>

<details>
<summary><b>3. Your app needs a connection string containing the password. How do you keep the ConfigMap/Secret split clean?</b></summary>

Compose the DSN in the pod spec. Put username, host, port and database in a
ConfigMap and only the password in a Secret, pull each into an environment
variable, then build the URL with `$(VAR)` interpolation in a later `env` entry.
Kubernetes expands it at container start, so the password is never duplicated
and the non-secret parts stay editable in the ConfigMap. The alternatives are
putting the whole URL in a Secret - simple but duplicates configuration - or
having the app accept separate parameters, which is cleanest when you control
the code.
</details>

<details>
<summary><b>4. What happens if an interpolated variable does not exist?</b></summary>

Nothing visible. Kubernetes leaves the `$(FOO)` token literally in the value and
starts the container, so the application receives a string containing the
placeholder and fails somewhere downstream - typically a DNS lookup for a
hostname called `$(POSTGRES_HOST)`. There is no admission-time validation, which
makes it a genuinely nasty typo class. Note also that variables coming from
`envFrom` are not reliably available for interpolation; define explicitly what
you interpolate.
</details>

<details>
<summary><b>5. data vs stringData?</b></summary>

`data` holds base64-encoded values and is what the API stores. `stringData` is
write-only convenience: you supply plaintext, the API server encodes it, and it
never appears when you read the object back. Use `stringData` in hand-written
manifests - it eliminates encoding mistakes including the trailing-newline bug
from `echo`.
</details>

<details>
<summary><b>6. Env var or volume mount for a secret?</b></summary>

Volume mount. Env vars are readable from `/proc/<pid>/environ` by anything in
the container, leak into crash dumps and any code that logs its environment, and
cannot be rotated without recreating the pod. Volume-mounted secrets live in
tmpfs and update in place. Env vars stay common because they are simpler and
many applications only support them.
</details>

<details>
<summary><b>7. How do you rotate a database password with zero downtime?</b></summary>

Make the database accept both old and new credentials during an overlap window -
for Postgres, a second role, or a staged ALTER USER. Update the Secret, then roll
the Deployment so pods pick up the new value, which is mandatory for env vars.
Once every pod runs the new credential, revoke the old one. Note that changing
POSTGRES_PASSWORD in the Secret does not change the password inside an
already-initialised database - that variable is only read on first init.
</details>

<details>
<summary><b>8. What breaks if a password contains @ or / and goes into a DSN?</b></summary>

The URL parser mis-splits it: an `@` ends the userinfo section early and a `/`
ends the host. The connection fails with a confusing error naming a host you
never configured. Passwords going into connection strings must be URL-encoded,
or generated from a URL-safe alphabet, or avoided entirely by passing separate
parameters.
</details>

<details>
<summary><b>9. How do pods authenticate to the Kubernetes API?</b></summary>

Through their ServiceAccount. Since 1.24 the kubelet projects a short-lived,
audience-bound token into the pod and refreshes it; long-lived token Secrets are
no longer auto-created. Pods that never call the API should set
`automountServiceAccountToken: false`.
</details>

<details>
<summary><b>10. A Secret manifest was pushed to a public repo. What now?</b></summary>

Rotate the credential immediately - it is compromised regardless of whether the
commit is deleted, because history and forks persist. Revoke it at the source
system, audit for use, then fix the process: pre-commit secret scanning, Sealed
Secrets or SOPS so only ciphertext is committable, and ideally workload identity
so there is nothing to leak.
</details>

---

## Cheat card

```bash
# create
kubectl create secret generic s --from-literal=K=V -n devboard
kubectl create secret generic s --from-file=K=file.txt -n devboard
kubectl create secret tls devboard-tls --cert=tls.crt --key=tls.key -n devboard
kubectl create secret docker-registry regcred \
  --docker-server=ghcr.io --docker-username=u --docker-password=p -n devboard

# read
kubectl describe secret devboard-secrets -n devboard          # byte counts only
kubectl get secret devboard-secrets -n devboard \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# every key at once
kubectl get secret devboard-secrets -n devboard -o go-template=\
'{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'

# encode / decode
echo -n 'value' | base64          # -n MATTERS
echo 'dmFsdWU=' | base64 -d

# what did the container actually receive?
kubectl exec -n devboard deploy/backend -- env | grep POSTGRES_URL

# after rotating
kubectl rollout restart deployment/backend -n devboard
```

**Carry forward:** a Secret is only as safe as the RBAC around it, and the best
secret is one that never exists.

---

**Next: [Day 11 - Postgres with config and secrets](../day-11-postgres-with-config-and-secrets/)**
