# CKA 13 — TLS in Kubernetes

**Time:** 120-150 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [CKA 03](../03-etcd-and-cluster-data/), [CKA 05](../05-manual-scheduling-and-static-pods/)
**Source lectures:** 141, 142, 143, 144, 145, 146, 147, 148, 151

Every component in a Kubernetes cluster authenticates every other component with
a certificate. There is no password anywhere. When a cluster breaks in a way
that looks inexplicable, this is very often why — and diagnosing it is one of
the highest-value skills on the exam and off it.

**Follow-on:** [CKA 15](../15-certificates-api-and-authorization/) covers the
CertificateSigningRequest API — signing certificates *through* Kubernetes. This
assignment is the layer underneath: the files themselves.

---

## Part 1 - Concepts

### 13.1 The 90-second version of TLS

Symmetric encryption uses one key for both directions. It is fast, and it has
one fatal problem: **both sides need the key before they can talk securely**, and
handing it over is the very thing they cannot do yet.

Asymmetric encryption solves that with a **pair**: what one key locks, only the
other opens.

```
  CLIENT                                     SERVER
    |  "hello"                                 |
    |----------------------------------------->|
    |          certificate (public key)        |
    |<-----------------------------------------|
    |  verify the signature on that cert       |
    |  against a CA I already trust            |
    |                                          |
    |  symmetric key, encrypted with           |
    |  the server's public key                 |
    |----------------------------------------->|
    |                     only the server's private key
    |                     can decrypt it
    |  ...everything after this is symmetric   |
```

The asymmetric part exists **only to exchange a symmetric key safely**. Once
that is done, TLS goes back to fast symmetric encryption.

**What stops an impostor sending its own public key?** The certificate is signed
by a **certificate authority** that both sides already trust. A signature you
cannot verify is not a mystery to investigate — it is a rejection.

**Client certificates** are the same mechanism pointed the other way: the server
demands that the *client* prove who it is. Kubernetes uses this constantly, which
is what makes it different from the average website.

### 13.2 Reading filenames

You are about to meet thirty certificate files. This convention keeps them
straight:

| Contains | Extension |
|---|---|
| **public** — a certificate | `.crt`, `.pem` |
| **private** — a key | `.key`, or `-key.pem` |

**If the word "key" appears, it is secret.** Everything else is public and
designed to be handed out. `apiserver.crt` goes to anyone who asks;
`apiserver.key` leaving the node is an incident.

### 13.3 Three roles, one mechanism

| Role | Who has it | Purpose |
|---|---|---|
| **Server certificate** | API server, etcd, kubelet | prove *I am the server you dialled* |
| **Client certificate** | admin, scheduler, controller-manager, kube-proxy, kubelet | prove *I am who I claim to be* |
| **Root CA certificate** | **everyone** | verify the other side's signature |

The third is the one people forget. **Every component needs the CA certificate**,
whether it is acting as a server, a client, or both — otherwise it has no way to
judge the certificate it was handed.

### 13.4 Who talks to whom

```
                     +---------------------+
   admin (kubectl)-->|                     |
   scheduler ------->|   kube-apiserver    |---> etcd        (as a CLIENT)
   controller-mgr -->|   (SERVER)          |---> kubelet     (as a CLIENT)
   kube-proxy ------>|                     |
   kubelet --------->+---------------------+
```

Three components are **servers**: `kube-apiserver`, `etcd`, `kubelet`.

Everything else is a **client** of the API server — and to the API server, the
scheduler is no more privileged than you at a terminal. Both present a client
certificate; both are judged the same way.

**The API server is both.** It serves its own API *and* it is a client of etcd
and of every kubelet. That is why it holds several certificates, and why "the
apiserver certificate" is an ambiguous phrase that has caused real outages.

### 13.5 There are two certificate authorities

kubeadm creates **two**, and confusing them is the single most common
certificate failure in a real cluster:

| CA | File | Signs |
|---|---|---|
| **`kubernetes`** | `/etc/kubernetes/pki/ca.crt` | the API server, all client certs, kubelets |
| **`etcd-ca`** | `/etc/kubernetes/pki/etcd/ca.crt` | the etcd server, etcd peers, and the API server's *etcd client* certificate |

**`--etcd-cafile` must point at the etcd CA, not the Kubernetes CA.** Point it at
the wrong one and etcd rejects the API server with `bad certificate` while the
API server reports `certificate signed by unknown authority`. Both messages are
true and neither names the file. You will fix exactly this in Part 2.

### 13.6 CN and O are username and group

This is where TLS stops being generic and becomes Kubernetes:

| Certificate field | Kubernetes reads it as |
|---|---|
| **`CN`** (Common Name) | the **username** |
| **`O`** (Organization) | the **group** — and it may appear more than once |

```bash
openssl req -new -key admin.key -subj "/CN=kubernetes-admin/O=system:masters" -out admin.csr
```

**That certificate makes you a cluster administrator**, and nothing in the
cluster grants it — `system:masters` is hard-wired into the API server's
authorizer and bypasses RBAC entirely. There is no Role, no RoleBinding, and no
way to revoke it short of rotating the CA.

The `system:` prefix is reserved for cluster components:

| Certificate | CN | O |
|---|---|---|
| admin | `kubernetes-admin` | `system:masters` |
| scheduler | `system:kube-scheduler` | — |
| controller manager | `system:kube-controller-manager` | — |
| kube-proxy | `system:kube-proxy` | — |
| **kubelet on node01** | **`system:node:node01`** | **`system:nodes`** |

The kubelet line is worth reading twice. **The node's name is inside its
username**, which is what lets the Node authorizer
([CKA 15](../15-certificates-api-and-authorization/)) restrict each kubelet to
the pods actually scheduled on that node. Change the CN and the kubelet
authenticates fine and is authorized for nothing.

### 13.7 The API server has many names

Clients reach the API server by at least six names, and **a certificate is only
valid for the names inside it**:

```
kubernetes
kubernetes.default
kubernetes.default.svc
kubernetes.default.svc.cluster.local
<the node's hostname>
<the node's IP>
<the ClusterIP of the kubernetes Service, usually 10.96.0.1>
```

All of them live in the certificate's **`subjectAltName`** extension. A modern
TLS client **ignores the CN for hostname matching** — if the name is not in the
SAN list, the connection fails, no matter how correct everything else is.

This is why putting a load balancer or a new DNS name in front of an existing
cluster breaks it: the certificate does not know about the new name, and the fix
is to reissue with `--apiserver-cert-extra-sans`, not to reconfigure the client.

### 13.8 Creating a certificate is always three commands

```bash
# 1. private key
openssl genrsa -out admin.key 2048

# 2. certificate signing request -- your details, no signature yet
openssl req -new -key admin.key -subj "/CN=kubernetes-admin/O=system:masters" -out admin.csr

# 3. sign it with the CA
openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 365
```

**Step 3 is where trust is conferred.** For the CA itself, step 3 is self-signed
with its own key — that is the only structural difference between a CA and
anybody else.

A CSR carries **no signature**, so it is not secret and can be emailed. The
`.key` from step 1 never moves.

### 13.9 Where everything lives

```
/etc/kubernetes/
  manifests/            static pod manifests -- every cert PATH is in here
    kube-apiserver.yaml
    etcd.yaml
  pki/
    ca.crt  ca.key                       the Kubernetes CA
    apiserver.crt  apiserver.key         API server SERVING cert
    apiserver-etcd-client.crt/.key       API server as a CLIENT of etcd
    apiserver-kubelet-client.crt/.key    API server as a CLIENT of kubelets
    front-proxy-ca.crt  front-proxy-client.crt
    sa.key  sa.pub                       ServiceAccount token signing (NOT a cert)
    etcd/
      ca.crt  ca.key                     the etcd CA -- a DIFFERENT authority
      server.crt  server.key             etcd SERVING cert
      peer.crt  peer.key                 etcd-to-etcd
      healthcheck-client.crt/.key
  admin.conf  scheduler.conf  controller-manager.conf  kubelet.conf
```

Two rules resolve most "which file?" questions:

- **Anything the API server uses is under `pki/`** — including its client
  certificates for etcd and for the kubelets.
- **Anything etcd uses for itself is under `pki/etcd/`** — including etcd's own
  CA.

The `.conf` files are kubeconfigs ([CKA 14](../14-kubeconfig-and-the-api/)) with
the client certificate embedded as base64 rather than referenced by path.

> **`sa.key` / `sa.pub` are not certificates.** They are a bare RSA key pair used
> to sign ServiceAccount tokens. Losing them invalidates every token in the
> cluster at once.

### 13.10 Inspecting a certificate

One command answers every question in this assignment:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout
```

Five fields matter:

| Field | Question it answers |
|---|---|
| `Subject: CN=..., O=...` | **who is this?** — username and group |
| `Issuer: CN=...` | **who signed it?** — `kubernetes` or `etcd-ca` |
| `X509v3 Subject Alternative Name` | **which hostnames is it valid for?** |
| `Validity: Not Before / Not After` | **is it expired?** |
| `X509v3 Extended Key Usage` | `TLS Web Server` / `TLS Web Client` — which direction |

`-noout` suppresses the base64 blob you do not want. Learn the command with the
flags attached; you will type it twenty times in Part 2.

kubeadm gives you a shortcut for the expiry question specifically:

```bash
kubeadm certs check-expiration
kubeadm certs renew apiserver          # or `all`
```

**`kubeadm certs renew` does not renew the CA.** It reissues leaf certificates
using the existing CA, which is exactly what you want for the annual expiry and
useless if the CA itself has expired.

### 13.11 When kubectl is gone

If the API server will not start, `kubectl` cannot tell you why — it is the thing
that is down. You drop one level, to the container runtime on the node:

```bash
crictl ps -a | grep apiserver          # note it has EXITED
crictl logs <container-id>
crictl logs --previous <container-id>
```

**Read the logs of the *exited* container**, not the one currently restarting.
This is the CKA 02 skill, and certificate failures are where you will use it.

The three messages you must recognise on sight:

| Message | Meaning |
|---|---|
| `certificate signed by unknown authority` | **wrong CA file** — the verifier does not trust the signer |
| `x509: certificate has expired or is not yet valid` | check `Not After`, and check the node's clock |
| `x509: certificate is valid for X, not Y` | **SAN mismatch** — you dialled a name not in the certificate |
| `bad certificate` (seen by the *server*) | the client presented something the server could not verify |
| `open /etc/kubernetes/pki/...: no such file` | wrong **path** in the manifest, not a certificate problem at all |

The last one is worth separating out. **Half of all "certificate errors" are
path errors**, and they are much easier to fix.

---

## Part 2 - Hands-on lab

```bash
CP=devops-control-plane
docker exec $CP cp -r /etc/kubernetes/manifests /root/manifests.backup
docker exec $CP ls /root/manifests.backup
```

**Take that backup.** Parts D and E deliberately break the control plane.

### A. Build the certificate inventory

This is the health check from the lecture, done properly. Every certificate the
API server uses is named in its manifest:

```bash
docker exec $CP grep -E "\-\-(tls|client|etcd|kubelet|service-account|proxy|requestheader).*(cert|key|ca)" \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
--client-ca-file=/etc/kubernetes/pki/ca.crt
--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
--etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
--etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
--kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
--tls-cert-file=/etc/kubernetes/pki/apiserver.crt
--tls-private-key-file=/etc/kubernetes/pki/apiserver.key
```

**Sort those eight into three groups before moving on** — it is the whole point
of the exercise:

| Group | Flags | The API server is... |
|---|---|---|
| serving | `--tls-cert-file`, `--tls-private-key-file` | a **server** |
| verifying clients | `--client-ca-file` | a **server** checking who called |
| calling etcd | `--etcd-*` | a **client** |
| calling kubelets | `--kubelet-client-*` | a **client** |

Now etcd's own:

```bash
docker exec $CP grep -E "\-\-(cert|key|trusted|peer|client)" /etc/kubernetes/manifests/etcd.yaml
```

```
--cert-file=/etc/kubernetes/pki/etcd/server.crt
--key-file=/etc/kubernetes/pki/etcd/server.key
--trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
--peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
--peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

**Notice which CA etcd trusts: `pki/etcd/ca.crt`, not `pki/ca.crt`.** Hold on to
that; part E turns on it.

Generate the full inventory table:

```bash
bash solution/cert-health-check.sh
```

```
FILE                                   SUBJECT CN                 ISSUER      EXPIRES        DAYS
pki/ca.crt                             kubernetes                 kubernetes  2035-xx-xx     3650
pki/apiserver.crt                      kube-apiserver             kubernetes  2026-xx-xx      364
pki/apiserver-etcd-client.crt          kube-apiserver-etcd-client etcd-ca     2026-xx-xx      364
pki/etcd/ca.crt                        etcd-ca                    etcd-ca     2035-xx-xx     3650
pki/etcd/server.crt                    devops-control-plane       etcd-ca     2026-xx-xx      364
...
```

**Read the ISSUER column.** Two distinct authorities, and each certificate is
signed by exactly one of them. `apiserver-etcd-client.crt` is issued by
**`etcd-ca`** even though it lives in `pki/` and belongs to the API server —
because the thing that must *verify* it is etcd.

### B. Decode certificates by hand

```bash
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | head -25
```

Answer these from the output — they are exam questions verbatim:

```bash
# what is the CN on the API server certificate?
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject

# who issued it?
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -issuer

# which names is it valid for?
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName

# how long is it valid, and how long is the CA valid?
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
docker exec $CP openssl x509 -in /etc/kubernetes/pki/ca.crt        -noout -dates
```

**One year for the leaf, ten for the CA.** That ratio is the design: leaves are
rotated routinely; the CA is not, because rotating it means touching every
component at once.

Now find `system:masters` in the wild:

```bash
docker exec $CP grep client-certificate-data /etc/kubernetes/admin.conf \
  | awk '{print $2}' | base64 -d | openssl x509 -noout -subject
```

```
subject=O = system:masters, CN = kubernetes-admin
```

**That is your `kubectl`.** `O=system:masters` is why you can do anything, and
it is not granted by any RBAC object in the cluster — check for yourself:

```bash
kubectl get clusterrolebinding -o wide | grep -i masters
```

`cluster-admin` is bound to the *group*, which the API server hard-codes. See
[CKA 15](../15-certificates-api-and-authorization/) for why this matters when
someone submits a CSR asking for that group.

Compare against a component certificate:

```bash
docker exec $CP grep client-certificate-data /etc/kubernetes/scheduler.conf \
  | awk '{print $2}' | base64 -d | openssl x509 -noout -subject -dates
```

```
subject=CN = system:kube-scheduler
```

**No `O`.** The scheduler is a plain user with no group, authorized entirely by a
ClusterRoleBinding you can read:

```bash
kubectl get clusterrolebinding system:kube-scheduler -o yaml | grep -A4 subjects
```

### C. Issue a certificate with openssl and use it

Three commands from 13.8, against the real cluster CA.

```bash
bash solution/make-user-cert.sh dev-alice developers
```

Watch what it does, then verify the result yourself:

```bash
openssl x509 -in /tmp/cka13/dev-alice.crt -noout -subject -issuer -dates
```

```
subject=O = developers, CN = dev-alice
issuer=CN = kubernetes
```

**Use it directly, with no kubeconfig at all:**

```bash
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
docker exec $CP cat /etc/kubernetes/pki/ca.crt > /tmp/cka13/ca.crt

curl -s --cacert /tmp/cka13/ca.crt \
     --cert   /tmp/cka13/dev-alice.crt \
     --key    /tmp/cka13/dev-alice.key \
     "$APISERVER/api/v1/namespaces/default/pods" | head -12
```

```
"message": "pods is forbidden: User \"dev-alice\" cannot list resource \"pods\"...
```

**Read that carefully — it is the good outcome.** `Forbidden`, not
`Unauthorized`. The certificate **authenticated** successfully: the API server
read `CN=dev-alice` and believed it. It then found no RBAC rule for that user
and refused. Authentication and authorization are separate stages
([CKA 15](../15-certificates-api-and-authorization/), [CKA 07](../07-admission-controllers/)),
and this one command shows both.

Contrast with a certificate the cluster does not trust:

```bash
bash solution/make-user-cert.sh --rogue-ca dev-mallory system:masters
curl -s --cacert /tmp/cka13/ca.crt \
     --cert /tmp/cka13/dev-mallory.crt --key /tmp/cka13/dev-mallory.key \
     "$APISERVER/api/v1/namespaces/default/pods" | head -5
```

```
"message": "Unauthorized"
```

**Mallory asked for `system:masters` and got nothing**, because the certificate
was signed by a CA the API server has never heard of. The group in a certificate
is worth exactly as much as the signature under it — which is why control of
`ca.key` *is* control of the cluster.

Now grant Alice something and watch the same request succeed:

```bash
kubectl create clusterrole pod-reader --verb=get,list --resource=pods
kubectl create clusterrolebinding alice-reads --clusterrole=pod-reader --user=dev-alice

curl -s --cacert /tmp/cka13/ca.crt \
     --cert /tmp/cka13/dev-alice.crt --key /tmp/cka13/dev-alice.key \
     "$APISERVER/api/v1/namespaces/default/pods" | head -5
```

The binding names `--user=dev-alice`, which is **the CN and nothing else**. That
string is the entire link between a file on your disk and a rule in the cluster.

### D. Break and fix: a wrong path

```bash
bash solution/break.sh 1
```

It changes one character in `etcd.yaml`. Wait ~30 seconds, then:

```bash
kubectl get nodes
```

```
The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?
```

**`kubectl` is gone, so stop using it.** Work the problem as in 13.11:

```bash
docker exec $CP crictl ps -a | grep -E "apiserver|etcd"
```

The API server is restarting and etcd has exited. **Start with the one that
exited first** — the API server is a *symptom*; etcd is the cause.

```bash
docker exec $CP sh -c 'crictl logs $(crictl ps -a --name etcd -q | head -1) 2>&1 | tail -5'
```

```
open /etc/kubernetes/pki/etcd/server-certificate.crt: no such file or directory
```

**That is not a certificate error.** It is a missing file. Confirm:

```bash
docker exec $CP ls /etc/kubernetes/pki/etcd/
```

`server.crt` exists; `server-certificate.crt` does not. Find and fix the
reference:

```bash
docker exec $CP grep cert-file /etc/kubernetes/manifests/etcd.yaml
docker exec $CP sed -i 's|server-certificate.crt|server.crt|' /etc/kubernetes/manifests/etcd.yaml
```

Then **wait.** etcd restarts first, and the API server only recovers on its next
restart attempt — a minute is normal:

```bash
for i in $(seq 1 60); do kubectl get --raw=/readyz 2>/dev/null && break; sleep 2; done
kubectl get nodes
```

**The lesson is the order of investigation.** `kubectl` failing says nothing
about *what* failed. `crictl ps -a` showed two broken containers, and the
dependency direction — the API server needs etcd, never the reverse — told you
which log to read.

### E. Break and fix: the wrong CA

```bash
bash solution/break.sh 2
```

This one is subtler. Wait ~40 seconds:

```bash
kubectl get nodes                       # refused again
docker exec $CP sh -c 'crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -8'
```

```
transport: authentication handshake failed: tls: failed to verify certificate:
x509: certificate signed by unknown authority
...failed to connect to 127.0.0.1:2379
```

And from the other side:

```bash
docker exec $CP sh -c 'crictl logs $(crictl ps -a --name etcd -q | head -1) 2>&1 | grep -i "rejected\|bad certificate" | tail -3'
```

```
rejected connection ... (error "remote error: tls: bad certificate")
```

**Two components, two messages, one cause, and neither names a file.** Port 2379
is etcd, so look at the API server's etcd flags:

```bash
docker exec $CP grep etcd /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
--etcd-cafile=/etc/kubernetes/pki/ca.crt          <-- WRONG
--etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
--etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
```

There it is (13.5). Prove it before you change anything:

```bash
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt -noout -issuer
docker exec $CP openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject
docker exec $CP openssl x509 -in /etc/kubernetes/pki/etcd/ca.crt -noout -subject
```

```
issuer=CN = etcd-ca            <-- signed by etcd-ca
subject=CN = kubernetes        <-- pki/ca.crt is a DIFFERENT authority
subject=CN = etcd-ca           <-- this is the one that can verify it
```

**That is the whole diagnosis, in three commands and no guessing.**

```bash
docker exec $CP sed -i 's|--etcd-cafile=/etc/kubernetes/pki/ca.crt|--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
for i in $(seq 1 60); do kubectl get --raw=/readyz 2>/dev/null && break; sleep 2; done
kubectl get nodes
```

### F. Expiry

```bash
docker exec $CP kubeadm certs check-expiration
```

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
apiserver                  Aug 20, 2026 12:00 UTC   364d            no
apiserver-etcd-client      Aug 20, 2026 12:00 UTC   364d            no
...
CERTIFICATE AUTHORITY      EXPIRES                  RESIDUAL TIME
ca                         Aug 17, 2035 12:00 UTC   9y
etcd-ca                    Aug 17, 2035 12:00 UTC   9y
```

Renew one, and watch the dates move:

```bash
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
docker exec $CP kubeadm certs renew apiserver
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
```

**The file changed but the running API server did not notice** — it read the
certificate at startup. Restart it the CKA 09 way:

```bash
docker exec $CP mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 8
docker exec $CP mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
for i in $(seq 1 60); do kubectl get --raw=/readyz 2>/dev/null && break; sleep 2; done
```

**Renewing a certificate and restarting the component that serves it are two
separate steps.** A renewal that nobody restarted is the reason clusters still
go down on expiry day after somebody "renewed everything".

### Restore and clean up

```bash
bash solution/restore.sh
kubectl delete clusterrolebinding alice-reads --ignore-not-found
kubectl delete clusterrole pod-reader --ignore-not-found
rm -rf /tmp/cka13
```

---

## Part 3 - Challenges

### C1 - Complete the health check

For **`/etc/kubernetes/pki/apiserver-kubelet-client.crt`**, produce the full row
of the inventory table: subject CN, organisation, issuer, validity window, key
usage. Then answer, from those fields alone:

1. Is this a server certificate or a client certificate?
2. Which component presents it, and to whom?
3. Which CA verifies it, and where does that CA's certificate live?
4. What group does it belong to, and why does that group exist?

### C2 - Name the file from the error

For each message, name the **specific file** that is wrong and the flag that
references it:

1. `etcd: rejected connection ... remote error: tls: bad certificate`
2. `x509: certificate is valid for 10.96.0.1, 172.18.0.2, not k8s.corp.example`
3. `Unable to authenticate the request due to an error: x509: certificate has expired`
4. `open /etc/kubernetes/pki/etcd/peer-cert.crt: no such file or directory`
5. `kubectl` reports `Unauthorized` for every command, immediately, with no delay

Number 5 is different in kind from the others — say how.

### C3 - Break scenario 3

```bash
bash solution/break.sh 3
```

The API server **comes up**, but `kubectl` will not talk to it. Diagnose it
without reading `break.sh`:

1. What does `kubectl get nodes` say, and why is that message different from the
   ones in parts D and E?
2. Prove the cause with one `openssl` command against the live endpoint.
3. What is the correct fix, and what is the tempting wrong fix that a search
   engine will suggest?

Recover with `bash solution/restore.sh`.

### C4 - Add a name

The cluster is about to sit behind `k8s.corp.example`. Today's certificate does
not include that name.

1. Show that it does not, with one command.
2. Give the kubeadm procedure to reissue the API server certificate with the new
   name added.
3. Say exactly which files must be deleted first and why kubeadm will otherwise
   do nothing.
4. Say what must happen after the files are regenerated.

### C5 - The CA has expired

`kubeadm certs check-expiration` shows the **CA** with 3 days left.

1. Explain why `kubeadm certs renew all` does not solve this.
2. Sketch the order of operations for rotating a cluster CA without a full
   rebuild, and identify the one step during which the cluster is unavoidably
   inconsistent.
3. Name the two artefacts outside `/etc/kubernetes/pki` that also have to be
   updated, and what breaks if you forget each.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the control plane is healthy and both CAs are present and distinct;
every certificate under `pki/` is issued by one of them; `--etcd-cafile` points
at the etcd CA; the API server certificate carries the expected SANs; the
`dev-alice` certificate exists, is signed by the cluster CA, and carries the CN
and O you asked for.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# the one command for everything
openssl x509 -in FILE -text -noout

# the four questions, one flag each
openssl x509 -in FILE -noout -subject       # who is it -- CN=user, O=group
openssl x509 -in FILE -noout -issuer        # who signed it -- kubernetes or etcd-ca
openssl x509 -in FILE -noout -dates         # is it expired
openssl x509 -in FILE -noout -ext subjectAltName    # which hostnames

# every certificate path the API server uses
grep -E "cert|key|ca-file" /etc/kubernetes/manifests/kube-apiserver.yaml

# expiry, everything at once, including the kubeconfigs
kubeadm certs check-expiration
kubeadm certs renew apiserver          # or `all`; then RESTART the component

# pull the client certificate out of a kubeconfig
grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -subject

# what the live endpoint is actually serving
openssl s_client -connect 127.0.0.1:6443 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates

# no kubectl? go one level down
crictl ps -a | grep apiserver
crictl logs <id>
```

**Traps**

- **There are two CAs.** `pki/ca.crt` signs the cluster; `pki/etcd/ca.crt` signs
  etcd. `--etcd-cafile` takes the etcd one.
- **`CN` is the username, `O` is the group.** RBAC binds to those strings and to
  nothing else.
- **`O=system:masters` is cluster-admin**, hard-coded, unrevokable, and not
  visible as an RBAC rule.
- **The API server certificate needs every name in its SAN list.** Modern
  clients ignore the CN for hostname matching.
- **`.key` is private, `.crt` is public.** Never move a `.key`; a `.csr` is
  harmless.
- **Anything the API server uses is under `pki/`**, even its etcd and kubelet
  *client* certificates. Anything etcd uses for itself is under `pki/etcd/`.
- **`kubeadm certs renew` does not renew the CA**, and does not restart anything.
- **`Forbidden` means authentication worked** and authorization did not.
  `Unauthorized` means the certificate itself was not accepted. These point at
  completely different files.
- **Half of "certificate errors" are wrong paths.** Read the log before opening
  `openssl`.
- **When `kubectl` is down, use `crictl`** — and read the logs of the **exited**
  container, not the restarting one.
- **Fix the cause, not the symptom.** A dead API server usually means dead etcd.
- **`sa.key` / `sa.pub` are not certificates** and do not appear in
  `check-expiration`.

---

**Previous:** [CKA 12 — Cluster Maintenance and etcd Backup](../12-cluster-maintenance/)
**Next:** [CKA 14 — KubeConfig and the API](../14-kubeconfig-and-the-api/)
