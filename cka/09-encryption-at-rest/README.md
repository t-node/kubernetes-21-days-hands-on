# CKA 09 — Encrypting Secret Data at Rest

**Time:** 75-90 minutes
**Prerequisites:** [CKA 03](../03-etcd-and-cluster-data/), [CKA 05](../05-manual-scheduling-and-static-pods/), [Day 10](../../days/day-10-secrets/)
**Source lectures:** 110, 111

[Day 10](../../days/day-10-secrets/) said, in passing, that a Secret is "not
encrypted, only encoded". This assignment makes you prove it — by reading the
password out of etcd with your own hands — and then fixes it.

---

## Part 1 - Concepts

### 9.1 Two different things called "secret"

```
  YOUR MANIFEST                 THE API                     etcd ON DISK
  password: hunter2   --base64--> ZGF0YTogaHVudGVyMg==  --> ???
                       ENCODING                             ENCRYPTION
                       (reversible by anyone)               (this assignment)
```

**Base64 is a transport encoding.** It exists so that binary values survive JSON
and YAML. It provides zero confidentiality:

```bash
echo 'c3VwZXJzZWNyZXQ=' | base64 -d      # supersecret
```

That is why a Secret manifest must never be committed to git. But it is **not**
what this assignment is about. The question here is what sits on the control
plane node's disk, in etcd's data directory, **after** the API server has
decoded your base64 and stored the value.

By default: the plaintext. Anyone who can read `/var/lib/etcd` — a backup file,
a snapshot on an S3 bucket, a stolen disk, a `root` shell on the control plane —
has every credential in the cluster. **An etcd snapshot (CKA 12) is a complete,
unencrypted copy of every Secret you own.**

### 9.2 EncryptionConfiguration

The fix is a file the API server reads at startup:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets                     # which RESOURCE TYPES to encrypt
    providers:                      # ORDER IS EVERYTHING
      - aescbc:
          keys:
            - name: key1
              secret: <32 bytes, base64>
      - identity: {}
```

Two rules govern that `providers` list, and every mistake in this topic comes
from missing one of them:

1. **The first provider encrypts.** Whatever is at the top is what new writes
   use.
2. **Every provider can decrypt.** The API server tries them in order until one
   succeeds, which is how you read data written under an older key.

> **`identity` means no encryption.** It is a real provider that writes
> plaintext. Put `identity` first and you have configured encryption that
> encrypts nothing — a configuration that looks correct in review and protects
> nothing. Put it *last* and it is exactly right: it lets the API server still
> read the plaintext records written before you turned encryption on.

### 9.3 The providers

| Provider | What it is | Use when |
|---|---|---|
| `identity` | **no encryption** — plaintext | last in the list, always; or first to decommission |
| `secretbox` | XSalsa20 + Poly1305 | a fast local-key option |
| `aescbc` | AES-CBC with PKCS#7 | the common local-key choice; what the exam shows |
| `aesgcm` | AES-GCM | **only with automated key rotation** — the key must change every 200k writes |
| `kms` (v2) | keys held by an external KMS | **production**. The data key never touches the node |

The distinction that matters for a real cluster: with `aescbc`, `aesgcm` and
`secretbox`, **the key is written in a file on the control-plane node** in plain
base64. You have moved the problem, not solved it — anyone who can read
`/etc/kubernetes/enc/enc.yaml` can decrypt the whole database. That is still a
large improvement (a stolen *snapshot* is now useless), but it is why production
clusters use `kms` v2, where the API server holds only a wrapped key and the
unwrapping happens in a KMS plugin.

Generate a key correctly:

```bash
head -c 32 /dev/urandom | base64
```

**32 bytes.** Not 32 characters of base64, not a passphrase. The API server
refuses to start if the decoded key is the wrong length.

### 9.4 Wiring it into the API server

The API server is a **static pod** (CKA 05), so the file must be both referenced
by a flag *and* mounted into the pod:

```yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
      volumeMounts:
        - name: enc
          mountPath: /etc/kubernetes/enc
          readOnly: true
  volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
```

**Forgetting the volume is the classic failure.** The flag points at a path that
does not exist inside the container, the API server exits, and `kubectl` stops
answering. The symptom looks like a broken cluster; the cause is one missing
mount. Diagnose it exactly as in CKA 07 — `crictl logs` on the node, because
`kubectl` is gone.

Since **1.26** you can add `--encryption-provider-config-automatic-reload=true`,
which makes the API server re-read the file when it changes. Key rotation then
needs no restart — but the *initial* wiring still does.

### 9.5 Encryption is not retroactive

This is the fact people forget and it is worth stating flatly:

**Turning on encryption does nothing to data already in etcd.**

Existing Secrets stay plaintext until something writes them again. To force
that:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

Read what that does: fetch every Secret, hand the identical content back. The
content is unchanged, so nothing observable happens — but each object is
**written again**, and this time through the encryption provider.

The same command is the last step of a **key rotation**, and the reason rotation
is a four-step dance:

| Step | `providers` order | Restart? | Then |
|---|---|---|---|
| 1 | `key1`, **`key2`**, identity | yes | new key present but unused — now every API server can *decrypt* key2 |
| 2 | **`key2`**, `key1`, identity | yes | new writes use key2 |
| 3 | — | no | `kubectl get secrets -A -o json \| kubectl replace -f -` |
| 4 | **`key2`**, identity | yes | key1 removed — safe only after step 3 |

**Skipping step 1 breaks a multi-master cluster**: one API server starts writing
with a key its peers cannot decrypt yet. **Skipping step 3 destroys data** — you
remove the only key that can read records still encrypted with it.

Decommissioning is the same logic in reverse: put `identity` **first**, restart,
rewrite everything, and only then delete the config and the key file.

---

## Part 2 - Hands-on lab

> This assignment edits the API server static pod manifest, exactly as CKA 07
> did. Take the backup first and read **Recovery** at the end before you start.

```bash
CP=devops-control-plane
docker exec $CP cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.backup.yaml
kubectl create namespace cka09
```

### Step 1: Encoding is not encryption

```bash
kubectl -n cka09 create secret generic my-secret --from-literal=key1=supersecret
kubectl -n cka09 get secret my-secret -o jsonpath='{.data.key1}{"\n"}'
kubectl -n cka09 get secret my-secret -o jsonpath='{.data.key1}' | base64 -d; echo
```

One command, no credentials beyond `get secret`, and the password is on screen.

### Step 2: Read the password straight out of etcd

Same `etcdctl` setup as [CKA 03](../03-etcd-and-cluster-data/):

```bash
ETCD="kubectl -n kube-system exec etcd-devops-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCD get /registry/secrets/cka09/my-secret | od -c | head -25
```

Among the binary you will find, in clear ASCII:

```
0000320   k   e   y   1  \n   s   u   p   e   r   s   e   c   r   e   t
```

Or, bluntly:

```bash
$ETCD get /registry/secrets/cka09/my-secret | grep -a -c supersecret     # 1
```

**That is the whole problem.** Not base64 — this is the raw byte stream on the
control-plane node's disk, and the password is in it. Every etcd snapshot you
have ever taken contains this.

> `od -c` rather than `hexdump`: it exists everywhere, including Git Bash on
> Windows. `xxd` works too.

### Step 3: Confirm encryption is off

```bash
docker exec $CP grep encryption-provider /etc/kubernetes/manifests/kube-apiserver.yaml
# (no output)
docker exec $CP sh -c "ps aux | grep [k]ube-apiserver | xargs -n1 | grep encryption"
# (no output)
```

Two independent checks — the manifest and the running process. Learn both; a
task may hand you a cluster where they disagree, which itself is the finding.

### Step 4: Generate a key and write the configuration

```bash
KEY=$(head -c 32 /dev/urandom | base64)
echo "$KEY"
```

```bash
bash solution/enable-encryption.sh
```

Read the script first — it performs, in order, exactly what you would do by
hand:

1. generates a 32-byte key
2. writes `enc.yaml` from `solution/encryption-config.yaml`, key substituted
3. `mkdir /etc/kubernetes/enc` on the node, `chmod 600` the file
4. adds `--encryption-provider-config=...` to the API server command
5. adds the `hostPath` **volume** and the **volumeMount**
6. waits for `/readyz`

```bash
docker exec $CP cat /etc/kubernetes/enc/enc.yaml
docker exec $CP grep -A3 -B1 "encryption-provider\|name: enc" \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

Confirm the API server actually restarted with it:

```bash
docker exec $CP sh -c "ps aux | grep [k]ube-apiserver | xargs -n1 | grep encryption"
```

### Step 5: Write a new Secret and look again

```bash
kubectl -n cka09 create secret generic my-secret-2 --from-literal=key2=topsecret

$ETCD get /registry/secrets/cka09/my-secret-2 | od -c | head -12
$ETCD get /registry/secrets/cka09/my-secret-2 | grep -a -c topsecret      # 0
```

The value is gone. What you see instead is the provider's envelope:

```
k8s:enc:aescbc:v1:key1:
```

**Read that prefix carefully** — it names the scheme (`aescbc`), the version,
and **which key** encrypted this record. That last field is how the API server
knows which key to try, and it is what makes rotation possible.

Meanwhile:

```bash
$ETCD get /registry/secrets/cka09/my-secret | grep -a -c supersecret      # still 1
```

**The old Secret is still plaintext.** Encryption is not retroactive (9.5). And
note that `kubectl get secret my-secret` still works perfectly — the `identity`
provider at the bottom of the list is decrypting it.

### Step 6: Rewrite everything

```bash
kubectl get secrets -A -o json | kubectl replace -f -
$ETCD get /registry/secrets/cka09/my-secret | grep -a -c supersecret      # 0
$ETCD get /registry/secrets/cka09/my-secret | od -c | head -4             # k8s:enc:aescbc:v1:key1:
```

Nothing about the Secret changed. It was simply **written again**, and this time
the write went through the provider.

```bash
kubectl -n cka09 get secret my-secret -o jsonpath='{.data.key1}' | base64 -d; echo
```

Still `supersecret` to any authorised client. **Encryption at rest changes
nothing for API users** — which is the point, and also the reason it is easy to
forget it is not on.

### Step 7: Rotate the key

The four-step dance from 9.5, for real.

```bash
bash solution/rotate-key.sh add          # step 1: key2 added SECOND
docker exec $CP cat /etc/kubernetes/enc/enc.yaml
$ETCD get /registry/secrets/cka09/my-secret | od -c | head -2    # still key1
```

Nothing has changed on disk — that is correct. All that happened is that every
API server can now *decrypt* key2.

```bash
bash solution/rotate-key.sh promote      # step 2: key2 moves FIRST
kubectl -n cka09 create secret generic rotated-probe --from-literal=a=b
$ETCD get /registry/secrets/cka09/rotated-probe | od -c | head -2
```

```
k8s:enc:aescbc:v1:key2:
```

New writes use key2; older records still say `key1` and still read fine.

```bash
kubectl get secrets -A -o json | kubectl replace -f -   # step 3: rewrite
$ETCD get /registry/secrets/cka09/my-secret | od -c | head -2   # now key2
```

```bash
bash solution/rotate-key.sh drop         # step 4: key1 removed
kubectl -n cka09 get secret my-secret -o jsonpath='{.data.key1}' | base64 -d; echo
```

Everything still reads. **Had you run `drop` before the rewrite, that command
would now return an error and the data would be unrecoverable** — the only key
able to decrypt it would be gone. Try it in your head; do not try it here.

### Step 8: Decommission properly

```bash
bash solution/disable-encryption.sh
```

The script does it in the safe order, and refuses to skip a step:

1. `identity` moved to the **top** — new writes are plaintext, old keys still
   present for reading
2. restart, wait for `/readyz`
3. `kubectl get secrets -A -o json | kubectl replace -f -` — everything back to
   plaintext
4. only now remove the flag, the mount, the volume and the key file

```bash
$ETCD get /registry/secrets/cka09/my-secret | grep -a -c supersecret     # 1 again
docker exec $CP grep -c encryption-provider /etc/kubernetes/manifests/kube-apiserver.yaml  # 0
docker exec $CP ls /etc/kubernetes/enc 2>&1                              # No such file
```

**Deleting the key file first would have bricked the cluster** — the API server
would restart, fail to open the file it is still configured to read, and never
come up.

### Recovery

If `kubectl` stops answering after any manifest edit:

```bash
docker exec $CP crictl ps -a | grep apiserver
docker exec $CP sh -c 'crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20'
docker exec $CP cp /root/apiserver.backup.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
```

The three messages you will actually meet:

| Log line | Cause |
|---|---|
| `error reading encryption provider configuration file ... no such file` | flag set, **volume not mounted** |
| `invalid key length` / `illegal base64` | the key is not 32 bytes, or has a stray newline |
| `resource "secrets" is masked by earlier rule` | duplicate `resources:` entries |

### Cleanup

```bash
kubectl delete ns cka09 --ignore-not-found
```

---

## Part 3 - Challenges

### C1 - Audit an unfamiliar cluster

You are handed a cluster. In five commands or fewer, answer:

1. Is encryption at rest enabled?
2. Which resource types are covered?
3. Which provider and which key name are in use for **new** writes?
4. Are there Secrets still stored in plaintext despite it being enabled?

Write the commands. Question 4 is the one people get wrong.

### C2 - Encrypt more than Secrets

Extend the configuration so that **ConfigMaps** are also encrypted, but with a
*different* key from Secrets. Write the file. Then say why encrypting
`configmaps` is a decision with a cost, and name one resource type it would be a
bad idea to encrypt.

### C3 - The unrecoverable rotation

A colleague rotated the key by editing `enc.yaml` to contain only `key2` and
restarting. `kubectl get secrets` now returns errors for some Secrets but not
others. Explain precisely what happened, what determines which Secrets still
work, and whether the data can be recovered. State the condition under which
recovery is possible.

### C4 - Snapshot forensics

Take an etcd snapshot (CKA 12) of a cluster with encryption enabled, and one
without. Show how you would demonstrate to an auditor that the first contains no
plaintext credentials and the second does. Give the commands.

### C5 - The honest threat model

Encryption at rest with `aescbc` stores the key in
`/etc/kubernetes/enc/enc.yaml` on the control-plane node. List the three attacks
this defends against and the two it does not, then say what `kms` v2 changes
about that list.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Run it **after Step 6** to check that encryption is on and everything is
rewritten; run it again after Step 8 to check the decommission was clean. It
detects which state you are in and checks the right things.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# is encryption on?
grep encryption-provider /etc/kubernetes/manifests/kube-apiserver.yaml
ps aux | grep [k]ube-apiserver | tr ' ' '\n' | grep encryption

# a 32-byte key
head -c 32 /dev/urandom | base64

# read a secret's raw bytes from etcd
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/<ns>/<name> | od -c | head

# re-encrypt everything already stored
kubectl get secrets -A -o json | kubectl replace -f -

# same, one namespace
kubectl get secrets -n <ns> -o json | kubectl replace -f -
```

The minimal configuration file, from memory:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64 32 bytes>
      - identity: {}
```

**Traps**

- **Base64 is not encryption.** If a task says "the secret must not be readable
  from etcd", base64 is not an answer.
- **The first provider encrypts; all of them decrypt.** `identity` first = no
  encryption at all.
- **Always keep `identity` last** while any plaintext record remains.
- **The key must decode to exactly 32 bytes.** `head -c 32 /dev/urandom | base64`.
  A trailing newline inside the YAML value will break startup.
- **The flag alone is not enough** — add the `hostPath` volume *and* the
  `volumeMount`, or the API server will not start.
- **Encryption is not retroactive.** Existing Secrets need
  `kubectl get secrets -A -o json | kubectl replace -f -`.
- **Rotation order:** add second → promote to first → rewrite → remove old.
  Removing the old key before the rewrite loses data permanently.
- **Decommission order is the reverse:** `identity` first → rewrite → then
  remove the file. Deleting the key file first stops the API server.
- The API version is **`apiserver.config.k8s.io/v1`** — not
  `admissionregistration`, not `v1beta1`.
- `EncryptionConfiguration` is **a file on disk**, not an API object. `kubectl
  get encryptionconfiguration` does not exist.
- **`kubectl` behaves identically either way**, so you can never tell whether
  encryption is on by looking at a Secret through the API. Only the manifest,
  the process, or etcd tell you.

---

**Previous:** [CKA 08 — Commands and Arguments](../08-commands-and-arguments/)
**Next: CKA 10 — Multi-Container Pods and Init Containers** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
