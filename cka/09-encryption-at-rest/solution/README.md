# CKA 09 solution

## Challenge answers

### C1 - Audit an unfamiliar cluster

```bash
# 1+2+3 -- is it on, what does it cover, which provider/key encrypts new writes?
ssh control-plane 'grep encryption-provider /etc/kubernetes/manifests/kube-apiserver.yaml'
ssh control-plane 'cat /etc/kubernetes/enc/enc.yaml'      # path comes from the flag above

# 4 -- is anything STILL plaintext?
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets --prefix | grep -a -c "k8s:enc:"
# ...compare against:
kubectl get secrets -A --no-headers | wc -l
```

**Question 4 is the one people get wrong**, in two different ways:

- Answering it from the config file. The file tells you what happens to *new*
  writes. It says nothing about what is already stored.
- Answering it by reading a Secret through `kubectl`. That always works, whether
  the record is encrypted or not — the API server decrypts transparently.

**Only etcd can answer question 4.** If the count of `k8s:enc:` prefixes is
lower than the number of Secrets, some were written before encryption was
enabled and nobody ran the rewrite.

Reading `providers[0]` also answers question 3 — and if it is `identity`, the
honest answer to question 1 is **no**, however configured it looks.

### C2 - Encrypt more than Secrets

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: secrets-key1
              secret: <32 bytes base64>
      - identity: {}
  - resources:
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: configmaps-key1
              secret: <a DIFFERENT 32 bytes base64>
      - identity: {}
```

`resources` is a **list of rules**, each with its own provider list — that is how
you give two resource types two different keys. **The first matching rule wins**,
so a resource named twice makes the second entry dead configuration; the API
server logs `resource "x" is masked by earlier rule` and refuses to start.

**The cost of encrypting ConfigMaps:** ConfigMaps are read constantly and by far
more components than Secrets — every pod start that mounts one, every controller
that watches one. Encryption adds a decrypt on every read that misses the API
server's cache, and it makes the data unrecoverable from a snapshot if the key
is lost. You have taken a resource that is deliberately *not* confidential and
given it the failure modes of one that is. Do it when ConfigMaps in your cluster
genuinely carry sensitive data — which usually means the real fix is moving that
data into Secrets.

**A bad idea to encrypt:** `events`. They are high-volume, short-lived, carry
nothing confidential, and encrypting them buys nothing while adding CPU to the
hottest write path in the cluster. `endpointslices` and `leases` are the same
argument — churny, worthless to an attacker.

### C3 - The unrecoverable rotation

**What happened:** the colleague replaced the key list rather than extending it.
`key1` is gone from the configuration, so the API server has no way to decrypt
any record whose envelope reads `k8s:enc:aescbc:v1:key1:`. Those Secrets return
an internal error on read. They are not deleted — the ciphertext is intact in
etcd — but nothing in the cluster can open it.

**What determines which Secrets still work:**

| Secret | Envelope | Works? |
|---|---|---|
| written before encryption was ever enabled | none (plaintext) | **yes** — if `identity` is still in the list |
| written under key1 | `...:key1:` | **no** |
| written after the bad rotation | `...:key2:` | **yes** |

So the pattern the colleague sees — some Secrets fine, some broken — is exactly
what a lost key looks like, and it is the diagnostic. Confirm it directly:

```bash
etcdctl get /registry/secrets --prefix | grep -a -o 'k8s:enc:[^:]*:v1:[^:]*:' | sort | uniq -c
```

That prints a count per key name. A key name appearing there that is *not* in
`enc.yaml` is the problem, stated precisely.

**Can it be recovered? Yes — if and only if the old key material still exists
somewhere.** The ciphertext is unharmed; only the key was removed from the
config. Recovery:

1. find `key1` — the previous `enc.yaml` in a backup, in configuration
   management, in shell history, in an etcd snapshot of `/etc/kubernetes`
2. add it back to the `keys` list (position does not matter for decryption)
3. restart the API server
4. `kubectl get secrets -A -o json | kubectl replace -f -` to re-encrypt
   everything under the current first key
5. only then remove `key1` again

**If the key material is genuinely gone, the data is gone.** There is no
recovery path, by design — that is what encryption means. The affected Secrets
must be recreated from their original sources, which is the moment everybody
discovers whether those sources still exist.

This is why step 1 of the rotation dance ("add second, do not promote") exists,
and why `enc.yaml` belongs in the same backup regime as the etcd snapshot.

### C4 - Snapshot forensics

```bash
# 1. take the snapshot (CKA 12)
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/snap.db

# 2. the snapshot is just a bolt database file -- search its bytes
grep -a -c "supersecret" /tmp/snap.db          # unencrypted cluster: >= 1
grep -a -c "k8s:enc:"    /tmp/snap.db          # encrypted cluster:  >= 1

# 3. the same question without knowing any passwords in advance:
#    count Secret records vs encrypted envelopes
grep -a -o "/registry/secrets/[a-z0-9./-]*" /tmp/snap.db | sort -u | wc -l
grep -a -c "k8s:enc:" /tmp/snap.db
```

**The demonstration to an auditor is the `grep` on the snapshot file itself**,
not anything involving `kubectl`. Two artefacts side by side:

- unencrypted cluster: `grep -a supersecret snap-plain.db` prints a match, and
  `strings snap-plain.db | grep -A2 /registry/secrets/` shows values in clear
- encrypted cluster: the same greps find nothing, and every
  `/registry/secrets/...` key is followed by a `k8s:enc:aescbc:v1:...` envelope

State the caveat honestly, because a good auditor will ask: **this proves the
snapshot is protected, not the cluster.** The key file lives on the control-plane
node. Anyone with root there has both halves. What you have actually eliminated
is the risk from the snapshot travelling — to a backup bucket, a laptop, a
support ticket — which is where these leaks really happen.

If the auditor's question is "can an attacker with the backup read our
credentials", the answer is now no. If it is "can an attacker with the control
plane", the answer is still yes, and only `kms` v2 changes it.

### C5 - The honest threat model

**Defends against:**

1. **A stolen or leaked etcd snapshot.** Backups get copied to object storage,
   attached to tickets, and restored onto test clusters. This is the dominant
   real-world exposure and encryption at rest removes it entirely.
2. **Disk-level access without OS access** — a decommissioned or stolen disk, a
   cloned volume, a snapshot of the VM's block device, a filesystem-level backup
   of `/var/lib/etcd`.
3. **A compromised etcd, or anyone with etcd client certificates.** Reading
   `/registry/secrets` directly now yields ciphertext. Note this is a real
   boundary: etcd credentials and control-plane root are not the same thing.

**Does not defend against:**

1. **Root on the control-plane node.** `/etc/kubernetes/enc/enc.yaml` is a
   plain-base64 key in a file, readable by anyone who can read the API server's
   own certificates. Encryption and key sit on the same machine.
2. **Anyone authorised to read Secrets through the API.** `kubectl get secret -o
   yaml` is unchanged, which is the entire design goal. If your threat is an
   over-broad RBAC role, encryption at rest does nothing whatsoever — the fix is
   [Day 19](../../../days/day-19-rbac/) and an audit of who holds `get` on
   `secrets`.

**What `kms` v2 changes:** the API server no longer holds the key that decrypts
your data. It holds a **wrapped** data-encryption key and calls a KMS plugin over
a local socket to unwrap it; the key-encryption key lives in an HSM or cloud KMS
and never reaches the node. That moves item (1) from "does not defend" to
"partially defends": root on the control plane can still ask the plugin to
unwrap, so a live attacker is not stopped — but the *files on the node* are no
longer sufficient, so a stolen disk, a filesystem backup, and a node image are
all now useless. It also gives you a real audit trail (the KMS logs every unwrap)
and rotation that does not require touching every node.

**The honest one-sentence summary:** encryption at rest protects data that has
*left* the cluster, and does approximately nothing against an attacker who is
*inside* it.

---

## Files

| File | Purpose |
|---|---|
| `encryption-config.yaml` | the `EncryptionConfiguration` template, `KEY1_PLACEHOLDER` filled in at deploy time |
| `enable-encryption.sh` | key, config, node placement, flag, volume, volumeMount, restart |
| `rotate-key.sh` | `add` / `promote` / `drop` -- the rotation dance, one step per invocation |
| `disable-encryption.sh` | decommission in the safe order, including the rewrite |
| `read-from-etcd.sh` | show a Secret's raw bytes and report whether a plaintext needle is present |
| `_apiserver-lib.sh` | shared helpers: backup, restart, readiness wait, etcdctl wrapper |
| `verify.sh` | detects the current state and checks the right things for it |

> `encryption-config.yaml` is **a file on disk read by the API server**, not an
> API object. `kubectl apply -f solution/` would reject it, and there is nothing
> in this directory meant to be applied.

---

## Why the scripts restart the API server the way they do

`restart_apiserver` in `_apiserver-lib.sh` moves the static pod manifest out of
`/etc/kubernetes/manifests` and back:

```bash
docker exec $CP mv $MANIFEST /tmp/kube-apiserver.yaml
# ...wait for the container to disappear...
docker exec $CP mv /tmp/kube-apiserver.yaml $MANIFEST
```

The kubelet watches that directory (CKA 05). Removing the file stops the pod;
restoring it starts a fresh one. This is deterministic in a way the alternatives
are not:

- `touch` on the manifest may not change anything the kubelet considers
- `kubectl delete pod kube-apiserver-<node>` deletes the **mirror** pod, and the
  kubelet's response to that has varied across releases
- `crictl rm` on the container fights the kubelet rather than working with it

**Note it is only needed because the file changed, not the manifest.** Editing
the manifest itself — as `enable-encryption.sh` does — already triggers a
restart. Since 1.26,
`--encryption-provider-config-automatic-reload=true` removes the need for the
restart on key changes entirely, which is what makes automated rotation
practical.

## A note on what these scripts deliberately do not do

`rotate-key.sh` will not run the rewrite for you. Step 3 —
`kubectl get secrets -A -o json | kubectl replace -f -` — is left in your hands
on purpose, because **skipping it is the mistake that destroys data**, and a
script that hides the step teaches you nothing about why `drop` is dangerous.

`disable-encryption.sh` *does* run the rewrite, because there the direction is
safe (encrypted to plaintext) and skipping it before deleting the key file would
leave unreadable records with no recovery path.
