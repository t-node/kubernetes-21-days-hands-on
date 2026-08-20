# CKA 05 — The Certificates API and Authorization Modes

**Time:** 75-90 minutes
**Prerequisites:** [CKA 04](../14-kubeconfig-and-the-api/), [Day 19](../../days/day-19-rbac/)

Day 19 showed you the certificate flow for onboarding a user and then said
"read this, do not run it". Today you run it — properly, through the Kubernetes
API rather than by hand on a CA server.

You will also fill the gap Day 19 left open: RBAC is one of **several**
authorization modes, and knowing how they chain is exam material.

---

## Part 1 - Concepts

### 5.1 The problem the Certificates API solves

Onboarding a new administrator, done by hand:

1. She generates a private key and a **certificate signing request** (CSR).
2. She emails you the CSR.
3. You **log into the CA server**, sign it with the CA key, get a certificate.
4. You email the certificate back.
5. It expires in a year and you do all of it again.

That works for one admin. It does not work for fifty, and it does not work at
all for automated rotation.

**Where is the CA server?** It is not a server — it is a **key pair**:
`ca.crt` and `ca.key`. Whoever holds those can mint a certificate for any
identity with any group, including `system:masters`. There is no revocation
list, so a leaked `ca.key` means rebuilding the cluster's trust from scratch.

```bash
docker exec devops-control-plane ls -la /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.key
```

On a kubeadm cluster — including yours — those sit on the **control-plane node**,
which therefore *is* your CA server. In a hardened setup they live somewhere
else entirely and that machine is the only place signing happens.

The **Certificates API** turns steps 2-4 into Kubernetes objects: the user's
request becomes a `CertificateSigningRequest`, you approve it with `kubectl`, and
the cluster signs it for you. No SSH, and every approval is an auditable API
call.

### 5.2 The CSR object

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: akshay
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400          # 24h; optional, 1.22+
  usages:
    - client auth
  request: LS0tLS1CRUdJTiBDRVJU...  # base64 of the .csr file
```

| Field | Means |
|---|---|
| `request` | the `.csr` file, **base64-encoded**, on **one line** |
| `signerName` | which signer handles this, and what kind of certificate it is |
| `usages` | `client auth` for a user; `server auth` for a serving certificate |
| `expirationSeconds` | requested validity; the signer may shorten it |

The signers you will meet:

| signerName | For |
|---|---|
| `kubernetes.io/kube-apiserver-client` | **a human or service client** — this is the one |
| `kubernetes.io/kube-apiserver-client-kubelet` | kubelet client certs (auto-approved) |
| `kubernetes.io/kubelet-serving` | kubelet serving certs |

> ### The `base64 -w 0` trap
>
> `base64` wraps output at 76 characters by default. A wrapped value inside a
> YAML scalar is invalid and you get:
>
> ```
> error: error parsing akshay.yaml: illegal base64 data at input byte ...
> ```
>
> Always disable wrapping:
>
> ```bash
> cat akshay.csr | base64 -w 0
> cat akshay.csr | base64 | tr -d '\n'    # macOS, no -w flag
> ```
>
> This costs people minutes in the exam. It cost the instructor minutes on video.

### 5.3 The workflow

```bash
# --- the user, on her machine ---
openssl genrsa -out akshay.key 2048
openssl req -new -key akshay.key -out akshay.csr -subj "/CN=akshay/O=developers"
#                                                       ^^^^^^^^ ^^^^^^^^^^^^^^
#                                                       username    group

# --- you, the administrator ---
kubectl apply -f akshay-csr.yaml       # with request: $(base64 -w 0 akshay.csr)
kubectl get csr                        # CONDITION: Pending
kubectl certificate approve akshay
kubectl get csr akshay -o jsonpath='{.status.certificate}' | base64 -d > akshay.crt

# --- and it still grants nothing until you bind a Role ---
kubectl create rolebinding akshay-view --clusterrole=view --user=akshay -n devboard
```

**That last line is the point most people miss.** A signed certificate makes you
*authenticated* — the cluster knows who you are. It grants **zero** permissions.
`CN=akshay` is just a string until an RBAC binding references it.

### 5.4 Who actually signs

Not the API server. **The controller manager** — it runs `csrapproving` and
`csrsigning` controllers:

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml"
```

```
--cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
--cluster-signing-key-file=/etc/kubernetes/pki/ca.key
```

**Those two flags are the CA.** Remove them and `kubectl certificate approve`
appears to succeed — the object flips to `Approved` — but no certificate is ever
issued, because nothing can sign. `Approved` and `Issued` are two separate
conditions, which is worth remembering when a CSR is approved and still has no
certificate.

### 5.5 Approving is a security decision, not a formality

A CSR carries whatever `O` values the requester chose:

```yaml
spec:
  groups:
    - system:masters          # <-- cluster-admin, by default
    - system:authenticated
```

Approve that and you have handed over the cluster. **Always read the groups
before approving:**

```bash
kubectl get csr <name> -o jsonpath='{.spec.groups}'
kubectl get csr <name> -o yaml
```

`kubectl certificate deny` refuses it. You cannot un-approve — deny is only
valid while the request is still `Pending`, so read first, then act.

### 5.6 Authorization modes

Day 19 covered RBAC. RBAC is one of **five** modes:

| Mode | Decides based on | Used for |
|---|---|---|
| **Node** | the requester is a kubelet (`system:nodes` group, `system:node:<name>` name) | kubelets reading their own pods, services, secrets |
| **RBAC** | Roles and bindings | **humans and service accounts — the main one** |
| **ABAC** | a JSON policy file on disk | legacy. Needs an API server restart per change |
| **Webhook** | an external HTTP service decides | Open Policy Agent, custom policy engines |
| **AlwaysAllow / AlwaysDeny** | nothing | testing only |

Set on the API server:

```bash
--authorization-mode=Node,RBAC
```

**If the flag is absent it defaults to `AlwaysAllow`** — every request permitted,
no checks at all.

The chain works like this:

```
request --> [Node] --deny--> [RBAC] --deny--> [Webhook] --deny--> 403 Forbidden
              |                |                  |
            allow            allow              allow
              v                v                  v
                    request proceeds
```

Two rules:

- **Any module that allows ends the chain immediately** — no further checks.
- **A denial just moves to the next module.** Only when *every* module has
  denied do you get `403`.

So the order in `--authorization-mode` matters for performance, not outcome —
and adding `AlwaysAllow` anywhere in the list makes everything after it
pointless.

**The Node authorizer** is why kubelets work without you writing RBAC for them.
It grants a narrow, fixed set of permissions to any identity named
`system:node:<nodename>` in group `system:nodes` — which is exactly the
`CN`/`O` pairing in a kubelet's client certificate. Certificate identity and
authorization meeting in one place.

---

## Part 2 - Hands-on lab

### Step 1: Confirm which authorization modes are active

Two ways, and you should know both — the second works when the manifest is not
where you expect:

```bash
docker exec devops-control-plane sh -c \
  "grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml"

docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ube-apiserver | xargs -n1 | grep authorization-mode"
```

```
--authorization-mode=Node,RBAC
```

Both `Node` and `RBAC`, in that order. Now find the signing configuration:

```bash
docker exec devops-control-plane sh -c \
  "grep -E 'cluster-signing' /etc/kubernetes/manifests/kube-controller-manager.yaml"
docker exec devops-control-plane ls -la /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.key
```

`ca.key` is mode `600` and root-owned. **That file is the cluster.**

### Step 2: Generate a key and a CSR as the new user

```bash
mkdir -p /tmp/cka05 && cd /tmp/cka05

openssl genrsa -out akshay.key 2048
openssl req -new -key akshay.key -out akshay.csr -subj "/CN=akshay/O=developers"

openssl req -in akshay.csr -noout -subject
# subject=CN = akshay, O = developers
```

`CN` is the username RBAC will match; `O` is a group. Nothing has been signed
yet — a CSR is only a request.

### Step 3: Encode it correctly

```bash
cat akshay.csr | base64 | head -3          # WRAPPED -- this will fail
echo "---"
cat akshay.csr | base64 -w 0 | head -c 80; echo "..."
```

The first is what breaks the manifest. Build the object with the second:

```bash
cat > akshay-csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: akshay
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - client auth
  request: $(cat akshay.csr | base64 -w 0)
EOF

grep -c '^' akshay-csr.yaml        # request must be ONE line
```

### Step 4: Submit and inspect

```bash
kubectl apply -f akshay-csr.yaml
kubectl get csr
```

```
NAME     AGE   SIGNERNAME                            REQUESTOR          CONDITION
akshay   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   Pending
```

**`Pending`.** Review it before approving — that is the whole job:

```bash
kubectl get csr akshay -o yaml | grep -A5 "spec:"
kubectl get csr akshay -o jsonpath='{.spec.groups}{"\n"}'
```

`developers` — a group with no bindings, so harmless.

### Step 5: Approve, and extract the certificate

```bash
kubectl certificate approve akshay
kubectl get csr akshay
```

`Approved,Issued` — two separate conditions, both needed.

```bash
kubectl get csr akshay -o jsonpath='{.status.certificate}' | base64 -d > akshay.crt
openssl x509 -in akshay.crt -noout -subject -issuer -dates
```

```
subject=O = developers, CN = akshay
issuer=CN = kubernetes
```

**Issued by your cluster's CA, valid for 24 hours** — the `expirationSeconds` you
asked for.

### Step 6: Build her a kubeconfig, and discover she can do nothing

```bash
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')

kubectl config --kubeconfig=/tmp/cka05/akshay.kubeconfig set-cluster devops \
  --server="$SERVER" --certificate-authority=/tmp/cka05/ca.crt --embed-certs=true
kubectl config --kubeconfig=/tmp/cka05/akshay.kubeconfig set-credentials akshay \
  --client-certificate=/tmp/cka05/akshay.crt --client-key=/tmp/cka05/akshay.key --embed-certs=true
kubectl config --kubeconfig=/tmp/cka05/akshay.kubeconfig set-context akshay@devops \
  --cluster=devops --user=akshay --namespace=devboard
kubectl config --kubeconfig=/tmp/cka05/akshay.kubeconfig use-context akshay@devops

kubectl --kubeconfig=/tmp/cka05/akshay.kubeconfig get pods
```

```
Error from server (Forbidden): pods is forbidden: User "akshay" cannot list
resource "pods" in API group "" in the namespace "devboard"
```

**`Forbidden`, not `Unauthorized`.** The cluster knows exactly who she is — the
certificate worked. She simply has no permissions. Authentication and
authorization are separate systems, and this is the cleanest demonstration of
it you will get.

Grant them:

```bash
kubectl create rolebinding akshay-view --clusterrole=view --user=akshay -n devboard
kubectl --kubeconfig=/tmp/cka05/akshay.kubeconfig get pods
kubectl --kubeconfig=/tmp/cka05/akshay.kubeconfig get secrets    # still Forbidden -- `view` excludes them
```

Note the binding names the **user string** `akshay`, matching the certificate's
`CN`. You could equally have bound the **group**:

```bash
kubectl create rolebinding devs-view --clusterrole=view --group=developers -n devboard
```

Binding to groups is how real teams do it: issue certificates with the right
`O`, and joiners need no new bindings at all.

### Step 7: The hostile CSR

```bash
cd /tmp/cka05
bash "$OLDPWD/solution/make-hostile-csr.sh" 2>/dev/null || \
  bash /c/Users/Admin/kubernetes-21-days-hands-on/cka/15-certificates-api-and-authorization/solution/make-hostile-csr.sh

kubectl get csr
```

A second request has appeared, `agent-smith`, which you did not create. Inspect
before doing anything:

```bash
kubectl get csr agent-smith -o jsonpath='{.spec.groups}{"\n"}'
kubectl get csr agent-smith -o yaml | grep -A6 "spec:"
```

```
["system:masters","system:authenticated"]
```

**`system:masters` is bound to `cluster-admin`.** Approving this hands over the
entire cluster. Refuse it:

```bash
kubectl certificate deny agent-smith
kubectl get csr agent-smith
kubectl delete csr agent-smith
```

`Denied`. **This is why approval is a human decision** — the requester chooses
the groups, and nothing stops them asking for anything.

### Step 8: Watch the authorization chain

```bash
kubectl auth can-i list pods -n devboard --as=akshay                      # yes  (RBAC)
kubectl auth can-i list pods -n devboard --as=nobody-at-all               # no   (nothing allows)
kubectl auth can-i list pods --as=system:node:devops-worker \
  --as-group=system:nodes                                                 # Node authorizer territory
```

The second returns `no` only after **both** Node and RBAC declined. The first
short-circuits at RBAC. Confirm the chain configuration once more:

```bash
docker exec devops-control-plane sh -c \
  "ps aux | grep [k]ube-apiserver | xargs -n1 | grep authorization-mode"
```

---

## Validate

```bash
cd /tmp/cka05
kubectl get csr akshay -o jsonpath='{.status.conditions[0].type}{"\n"}'   # Approved
openssl x509 -in akshay.crt -noout -subject                               # CN = akshay
kubectl --kubeconfig=akshay.kubeconfig get pods -n devboard >/dev/null && echo "akshay can list pods"
kubectl --kubeconfig=akshay.kubeconfig get secrets -n devboard 2>&1 | grep -c Forbidden
docker exec devops-control-plane sh -c \
  "grep -o 'authorization-mode=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml"
```

You are done when you can answer, without looking:

1. What are the two files that constitute the CA, and where are they?
2. Which component signs CSRs, and which two flags configure it?
3. Why must the `request` field be `base64 -w 0`?
4. A CSR is `Approved` but has no certificate. What is broken?
5. Name the five authorization modes and what happens when the flag is omitted.
6. In the chain, what happens on a deny? On an allow?
7. Your new user gets `Forbidden`, not `Unauthorized`. What does that tell you?

---

## Break it

**A. Wrapped base64.**

```bash
cd /tmp/cka05
sed "s|request: .*|request: $(cat akshay.csr | base64 | head -1)|" akshay-csr.yaml > bad.yaml
kubectl apply -f bad.yaml 2>&1 | tail -2
```

`illegal base64 data at input byte ...`. Exactly the failure from section 5.2.
Recognise it instantly and reach for `-w 0`.

**B. Approve without reading the groups.**

Re-create the hostile CSR and approve it deliberately, in this throwaway
cluster, to see what you would have handed over:

```bash
bash solution/make-hostile-csr.sh
kubectl certificate approve agent-smith
kubectl get csr agent-smith -o jsonpath='{.status.certificate}' | base64 -d > /tmp/cka05/evil.crt
openssl x509 -in /tmp/cka05/evil.crt -noout -subject
# subject=O = system:masters, CN = agent-smith
```

That certificate is `cluster-admin` on your cluster, valid until it expires, and
**there is no revocation list**. The only remedy is rotating the cluster CA.
Clean up:

```bash
kubectl delete csr agent-smith
rm -f /tmp/cka05/evil.crt
```

**C. Set the API server to AlwaysAllow.**

```bash
docker exec devops-control-plane sh -c \
  "sed -i 's|--authorization-mode=Node,RBAC|--authorization-mode=AlwaysAllow|' \
   /etc/kubernetes/manifests/kube-apiserver.yaml"
sleep 50

kubectl auth can-i delete nodes --as=akshay          # yes  (!!)
kubectl auth can-i '*' '*' --as=nobody-at-all        # yes  (!!)
```

**Every RBAC rule in the cluster is now decorative.** Every identity, including
ones that do not exist, can do everything. Restore immediately:

```bash
docker exec devops-control-plane sh -c \
  "sed -i 's|--authorization-mode=AlwaysAllow|--authorization-mode=Node,RBAC|' \
   /etc/kubernetes/manifests/kube-apiserver.yaml"
sleep 50
kubectl auth can-i delete nodes --as=akshay          # no
```

Remember that **omitting the flag entirely has the same effect** as setting
`AlwaysAllow`. On any cluster you inherit, check it first.

**D. Bind to a group instead of a user.**

```bash
kubectl delete rolebinding akshay-view -n devboard --ignore-not-found
kubectl --kubeconfig=/tmp/cka05/akshay.kubeconfig get pods -n devboard   # Forbidden

kubectl create rolebinding devs-view --clusterrole=view --group=developers -n devboard
kubectl --kubeconfig=/tmp/cka05/akshay.kubeconfig get pods -n devboard   # works
```

Nothing about `akshay` was named — the binding matched the `O=developers` in her
certificate. **Every future developer issued a certificate with that `O` is
authorised on day one, with no new bindings.** That is how this scales.

**E. Clean up.**

```bash
kubectl delete csr akshay agent-smith --ignore-not-found
kubectl delete rolebinding akshay-view devs-view -n devboard --ignore-not-found
rm -rf /tmp/cka05
```

---

## Exam-style tasks

Timed.

1. A CSR file is at `/tmp/exam/john.csr`. Create a CSR object named `john` with
   signer `kubernetes.io/kube-apiserver-client`, 1-hour validity. *(4 min)*
2. Approve it and save the issued certificate to `/tmp/exam/john.crt`. *(2 min)*
3. A CSR named `intruder` is Pending. Determine which groups it requests and
   take the appropriate action. *(3 min)*
4. Report the authorization modes on this cluster, two different ways. *(2 min)*
5. Grant `john` read-only access to the `devboard` namespace and prove it works
   without logging in as him. *(3 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# user side
openssl genrsa -out u.key 2048
openssl req -new -key u.key -out u.csr -subj "/CN=username/O=groupname"

# admin side
cat u.csr | base64 -w 0                     # -w 0 IS MANDATORY
kubectl apply -f csr.yaml
kubectl get csr
kubectl get csr NAME -o jsonpath='{.spec.groups}'      # READ BEFORE APPROVING
kubectl certificate approve NAME
kubectl certificate deny NAME
kubectl get csr NAME -o jsonpath='{.status.certificate}' | base64 -d > u.crt
kubectl delete csr NAME

# and it still grants nothing until:
kubectl create rolebinding rb --clusterrole=view --user=username  -n ns
kubectl create rolebinding rb --clusterrole=view --group=groupname -n ns
```

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: username
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
  request: <base64 -w 0 of the .csr>
```

| Where | What |
|---|---|
| `/etc/kubernetes/pki/ca.{crt,key}` | **the CA — protect these above all** |
| `kube-controller-manager.yaml` | `--cluster-signing-cert-file`, `--cluster-signing-key-file` |
| `kube-apiserver.yaml` | `--authorization-mode=Node,RBAC` |

| Mode | Decides on |
|---|---|
| `Node` | kubelets (`system:nodes` / `system:node:<name>`) |
| `RBAC` | Roles and bindings — the main one |
| `ABAC` | a JSON policy file; needs a restart to change |
| `Webhook` | an external service (OPA, custom) |
| `AlwaysAllow` | **the default when the flag is absent** |

**Chain:** any allow ends it; a deny moves to the next; all deny → `403`.

**Certificate → identity:** `CN` = user, `O` = group.
**Authentication ≠ authorization:** a valid certificate gets you `Forbidden`,
not `Unauthorized`.

---

**Previous:** [CKA 14 — KubeConfig and the API](../14-kubeconfig-and-the-api/)
**Next:** [CKA 16 — Service Accounts and Tokens](../16-service-accounts/)

**Back to the [CKA track](../) · [Main course](../../README.md)**
