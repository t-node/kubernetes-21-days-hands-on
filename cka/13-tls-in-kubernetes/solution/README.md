# CKA 13 solution

## Challenge answers

### C1 - Complete the health check

```bash
docker exec devops-control-plane openssl x509 \
  -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout
```

| Field | Value |
|---|---|
| Subject | `O = system:masters, CN = kube-apiserver-kubelet-client` |
| Issuer | `CN = kubernetes` |
| Validity | one year from cluster creation |
| Extended Key Usage | **TLS Web Client Authentication** |
| SAN | **none** |

**1. Client certificate.** Two independent proofs: `Extended Key Usage` says
`TLS Web Client Authentication`, and there is **no `subjectAltName`** — a server
certificate must carry the hostnames it serves, so a certificate with no SAN
cannot be a serving certificate.

**2. The API server presents it to the kubelets.** The name says so, and so does
the flag that references it:
`--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt`.
This is the API server acting as a **client** (13.4) — used for `kubectl logs`,
`kubectl exec`, `kubectl port-forward` and metrics, all of which the API server
fetches from the kubelet on your behalf.

**3. The Kubernetes CA verifies it** — `Issuer: CN=kubernetes`, whose certificate
is `/etc/kubernetes/pki/ca.crt`. The kubelet is configured with that same file
via `clientCAFile` in `/var/lib/kubelet/config.yaml`. **Not** the etcd CA: the
verifier here is the kubelet, which is part of the cluster proper.

**4. `O = system:masters`** — the same group as your admin certificate, so the
API server has unrestricted authority over every kubelet. That is deliberate:
the kubelet's authorization mode is typically `Webhook`, delegating decisions
back to the API server, and the component asking is the one being asked. The
consequence worth stating in an interview: **stealing
`apiserver-kubelet-client.key` gives you `exec` into any container on any node**,
bypassing the API server entirely — which is why the kubelet's read-only port and
anonymous auth are disabled by default.

### C2 - Name the file from the error

**1. `etcd: rejected connection ... tls: bad certificate`**
The client certificate the API server presented is not verifiable by etcd's
trusted CA. Either `--etcd-certfile`
(`/etc/kubernetes/pki/apiserver-etcd-client.crt`) is not signed by `etcd-ca`, or
etcd's `--trusted-ca-file` in `/etc/kubernetes/manifests/etcd.yaml` points at
the wrong CA. **This message is emitted by the server, so it names the client's
certificate — but the fix is usually on whichever side has the wrong CA.**

**2. `certificate is valid for 10.96.0.1, 172.18.0.2, not k8s.corp.example`**
`/etc/kubernetes/pki/apiserver.crt`, referenced by `--tls-cert-file`. A SAN
problem (13.7). The error helpfully lists exactly what the certificate does
cover. See C4 for the fix.

**3. `Unable to authenticate the request ... certificate has expired`**
The client's certificate — the one embedded in whichever kubeconfig made the
request, or a component's `.conf` file under `/etc/kubernetes/`. Identify it
with `kubeadm certs check-expiration`, which covers the kubeconfigs as well as
`pki/`. **Check the node's clock too**: a machine whose time has jumped forward
produces this error with certificates that are perfectly valid.

**4. `open .../etcd/peer-cert.crt: no such file`**
`--peer-cert-file` in `/etc/kubernetes/manifests/etcd.yaml`. **Not a certificate
error at all** — a path error. The real file is `peer.crt`. Fix the manifest, not
the certificate.

**5. `kubectl` reports `Unauthorized` immediately, for every command**

**This one is different in kind.** The four above are TLS failures — the
handshake itself did not complete, or a file could not be opened. Number 5 is a
successful TLS handshake followed by a rejected identity: the API server
accepted the connection, read the certificate, and did not recognise the signer
or the certificate is not being sent at all.

The distinguishing evidence:

```bash
kubectl get nodes -v=6        # shows the HTTP status: 401, not a dial error
```

A **401** means you reached the API server. A `connection refused` or
`TLS handshake timeout` means you did not. So for number 5 you look at your
**kubeconfig's `client-certificate-data`** and at `--client-ca-file` on the API
server — not at any serving certificate.

### C3 - Break scenario 3

**1. What `kubectl` says, and why it differs**

```
Unable to connect to the server: tls: failed to verify certificate:
x509: certificate signed by unknown authority
```

In parts D and E the message was `connection refused` — **nothing was
listening**, because the API server had crashed. Here the API server is up and
answering; it is *your client* that refuses to continue. The failure has moved
from the server to the handshake, and that is the whole diagnosis in one line:
**a running server whose certificate your kubeconfig's CA cannot verify.**

```bash
docker exec devops-control-plane crictl ps | grep apiserver     # Running
```

**2. Prove it with one command**

```bash
openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

```
subject=CN = kube-apiserver
issuer=CN = rogue-ca            <-- should be CN = kubernetes
```

**The live endpoint is serving a certificate signed by an authority the cluster
does not know.** Compare against what your client trusts:

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d | openssl x509 -noout -subject
```

**3. The correct fix, and the tempting wrong one**

Correct: **restore the API server's serving certificate** so it is once again
signed by the cluster CA — `bash solution/restore.sh`, or in a real cluster:

```bash
rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver
# then restart the API server so it reads the new file
```

**The tempting wrong fix is `--insecure-skip-tls-verify=true`** (or adding the
rogue CA to your kubeconfig). Both make the error disappear and both are
catastrophic: you have told your client to stop checking who it is talking to.
If this were not a lab, the situation you are looking at — *the API server is
suddenly presenting a certificate from an unknown CA* — is indistinguishable
from an interception attack, and the error is the control that caught it.

`--insecure-skip-tls-verify` has exactly one legitimate use: a cluster you built
sixty seconds ago whose CA you have not yet distributed. Never on a cluster that
was working yesterday.

### C4 - Add a name

**1. Show the name is absent**

```bash
docker exec devops-control-plane openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -ext subjectAltName
```

```
X509v3 Subject Alternative Name:
    DNS:devops-control-plane, DNS:kubernetes, DNS:kubernetes.default,
    DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local,
    IP Address:10.96.0.1, IP Address:172.18.0.2
```

No `k8s.corp.example`. Any client using that name gets
`certificate is valid for ..., not k8s.corp.example` (C2.2).

**2. The kubeadm procedure**

Add the name to the cluster configuration so it survives future upgrades, rather
than hand-editing:

```bash
kubectl -n kube-system get cm kubeadm-config -o yaml > kubeadm-config.yaml
# add under apiServer:
#   certSANs:
#     - k8s.corp.example
kubectl -n kube-system apply -f kubeadm-config.yaml

rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver --config kubeadm-config.yaml
```

For a one-off on a cluster being created, the same thing at init time is
`kubeadm init --apiserver-cert-extra-sans=k8s.corp.example`.

**3. Which files must be deleted first, and why**

`/etc/kubernetes/pki/apiserver.crt` **and** `apiserver.key`.

**`kubeadm init phase certs` is idempotent in the unhelpful direction**: if the
certificate already exists it validates it and leaves it alone, printing
something reassuring like `Using existing apiserver certificate authority`. It
will not regenerate over a file that is present. Delete both — the certificate
and its key — or you get a new certificate that does not match the retained key,
which fails in a much more confusing way than not regenerating at all.

**Do not delete `ca.crt` or `ca.key`.** Only the leaf. Removing the CA means
every certificate in the cluster becomes unverifiable at once (C5).

**4. What must happen afterwards**

**Restart the API server** — it read the old certificate at startup and has no
idea the file changed (part F):

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ && sleep 8 && mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

Then verify from the outside, not from the file:

```bash
openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

On a multi-master cluster, repeat on **every** control-plane node — each has its
own `apiserver.crt` with its own IP in the SAN list, and a load balancer will
happily send the next request to the one you forgot.

### C5 - The CA has expired

**1. Why `kubeadm certs renew all` does not help**

`kubeadm certs renew` **reissues leaf certificates using the existing CA**. It
signs with `ca.key` and copies `ca.crt` around unchanged — it never touches the
CA itself, and `kubeadm certs check-expiration` prints the CAs in a separate
section for exactly this reason.

Worse, it appears to work. It exits 0, the leaf certificates get new dates, and
`check-expiration` still shows the CA expiring in three days. If you stop there,
the cluster fails on schedule with every leaf certificate perfectly valid —
because a leaf signed by an expired CA is worthless. **The chain is only as valid
as its root.**

**2. The order of operations**

The safe method is a **dual-CA rollout**: distribute the new CA as *trusted*
before anything starts *presenting* certificates signed by it.

1. Generate a new CA (`ca-new.crt`, `ca-new.key`), keeping the old one.
2. **Concatenate both** into the trust bundle every verifier reads —
   `--client-ca-file`, the kubelet's `clientCAFile`, and the
   `certificate-authority-data` in every kubeconfig. Everyone now trusts both
   authorities and nothing has changed about what anyone presents.
3. Restart every component so the enlarged bundle is loaded. **Nothing has
   broken yet, and nothing will**, which is what makes this step safe to take
   slowly.
4. Swap `ca.crt`/`ca.key` for the new pair and reissue every leaf certificate
   against it (`kubeadm certs renew all`, now meaningful).
5. Restart every component again. Each now presents a new-CA certificate, and
   every verifier still trusts both.
6. Once nothing anywhere presents an old certificate, remove the old CA from the
   bundle and restart a final time.

**The unavoidably inconsistent moment is step 5**, and only step 5. Between the
first restarted component and the last, the cluster contains components
presenting new-CA certificates and components presenting old-CA ones. Because of
step 2 both are trusted, so the cluster keeps working — **the dual-trust window
exists precisely to make that inconsistency survivable.** Skip step 2 and step 5
becomes a hard outage: the first component you restart can no longer talk to any
component you have not yet restarted.

Order within step 5 matters too: restart the API server **last** among the
control plane, so that the components that depend on it are already speaking the
new language when it changes.

**3. The two artefacts outside `/etc/kubernetes/pki`**

**(a) Every kubeconfig.** `admin.conf`, `scheduler.conf`,
`controller-manager.conf`, `kubelet.conf` on every node, your own
`~/.kube/config`, and every CI or automation credential. Each embeds both a
client certificate signed by the old CA *and* a copy of the old CA in
`certificate-authority-data`. **If you forget these, `kubectl` stops working for
everybody the moment the API server switches** — and you have just removed your
own ability to fix the cluster. Regenerate them with
`kubeadm init phase kubeconfig all`, and remember the copies that live outside
the node.

**(b) The `kube-root-ca.crt` ConfigMap in every namespace.** Kubernetes projects
the cluster CA into every pod so that in-cluster clients can verify the API
server. It is created automatically per namespace, and **pods mount it, so they
hold a stale copy until they restart**. If you forget it, every in-cluster
controller, operator and application that talks to the API server starts failing
with `certificate signed by unknown authority` — including, on a bad day, the
webhooks from [CKA 07](../../07-admission-controllers/), which then block pod
creation and prevent the restarts that would fix it.

A third worth naming if you want one: **ServiceAccount tokens are not affected**
— they are signed by `sa.key`, not by the CA (13.9). That is a useful thing to
know under pressure, because it means workloads using ServiceAccount
authentication survive a CA rotation, while anything using a client certificate
does not.

**The honest summary:** rotating a cluster CA is a planned, multi-hour operation
with a rollback plan, not an incident response. The practical defence is that
kubeadm gives the CA **ten years** and the leaves **one** — so the CA expiring
means it was missed for a decade, and the real fix is an alert on
`check-expiration` long before that.

---

## Files

| File | Purpose |
|---|---|
| `cert-health-check.sh` | the inventory table: CN, O, issuer, expiry, days remaining, for every cert on the node |
| `make-user-cert.sh` | the three openssl commands from 13.8; `--rogue-ca` signs with an untrusted authority instead |
| `break.sh` | three certificate failures: wrong path, wrong CA, untrusted serving cert |
| `restore.sh` | undoes all three and waits for `/readyz` |
| `verify.sh` | checks every claim in Part 4 |

There are no `.yaml` files in this assignment. **Certificates are files on
nodes, not API objects** — which is the point, and the reason this material sits
below [CKA 15](../../15-certificates-api-and-authorization/) rather than beside
it.

---

## On copying `ca.key`

`make-user-cert.sh` does this:

```bash
docker cp devops-control-plane:/etc/kubernetes/pki/ca.key /tmp/cka13/ca.key
# ...sign...
rm -f /tmp/cka13/ca.key
```

**Never do this on a real cluster.** `ca.key` is the private key of the authority
that every component in the cluster trusts. Whoever holds it can mint a
certificate with `O=system:masters` and become cluster-admin, permanently and
invisibly — no RBAC object records it, no audit entry shows the certificate being
created, and revocation is not a thing X.509 gives you here. **Control of
`ca.key` is control of the cluster**, more completely than any Kubernetes
credential.

The script does it because it is the shortest honest way to show that signing is
the whole game, and it deletes the copy immediately.

**What you do instead** is the CertificateSigningRequest API
([CKA 15](../../15-certificates-api-and-authorization/)): the user generates a
key and a CSR, submits the CSR — which contains no secret — and an approver with
the right RBAC permission signs it *inside* the cluster. The private key never
moves, `ca.key` never leaves the control-plane node, and the whole exchange is
recorded as an API object you can list, audit and deny.

Read this assignment and CKA 15 as one story: **here is the machinery, and here
is the reason Kubernetes wrapped an API around it.**
