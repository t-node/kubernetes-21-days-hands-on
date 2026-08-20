# CKA 32 — JSONPath and Output Formatting

**Time:** 60-80 minutes
**Prerequisites:** [CKA 04](../04-imperative-declarative-and-apply/), [Day 02](../../days/day-02-kubectl-and-your-first-pod/)
**Source lectures:** 295, 296, 297, 298

This is a **speed** assignment. Every other assignment teaches you what something
is; this one teaches you to get an answer out of `kubectl` in one command instead
of five — worth marks in an exam and minutes in an incident.

---

## Part 1 - Concepts

### 32.1 The output formats

```bash
kubectl get pods -o wide            # more columns
kubectl get pods -o yaml            # everything, as YAML
kubectl get pods -o json            # everything, as JSON  <- what you EXPLORE with
kubectl get pods -o name            # pod/web-xxx  -- for piping
kubectl get pods -o jsonpath='...'  # one value, or many
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
kubectl get pods -o go-template='...'
```

| Use | When |
|---|---|
| `-o json` | **exploring** -- pipe it to `jq` and find the path |
| `-o jsonpath` | **extracting** -- you know the path and want the value |
| `-o custom-columns` | **tabulating** -- one row per object |
| `--sort-by` | ordering, and it takes a JSONPath |
| `-o name` | feeding another command |
| `-o go-template` | the rare thing JSONPath cannot express |

**The workflow is always the same** (32.9): dump JSON, find the path, write the
query.

### 32.2 JSONPath, in the amount that matters

```bash
kubectl get pods -o jsonpath='{.items[0].metadata.name}'
```

**Two syntax rules, and both catch people:**

- **The expression goes in `{}`.** Text outside the braces is printed literally.
- **Wrap the whole thing in single quotes** so the shell does not touch it.

| Syntax | Means |
|---|---|
| `.items` | a field |
| `.items[0]` | the first element |
| `.items[*]` | **every** element |
| `.items[-1:]` | the last element |
| `.items[?(@.spec.nodeName=="node1")]` | **a filter** -- `@` is the current element |
| `{range .items[*]}...{end}` | a loop |
| `\n`, `\t` | a newline, a tab |

**`{.items[*].metadata.name}` prints every name separated by spaces** — one line,
no structure. One per line needs a `range` (32.4).

> **`kubectl get pod NAME` returns a single object; `kubectl get pods` returns a
> `List`.** So `{.metadata.name}` works on the first and needs `{.items[0]...}`
> on the second. **This is the most common cause of empty output.**

### 32.3 Escaping dots in keys

Annotations and labels contain dots, and JSONPath treats a dot as a separator:

```bash
# WRONG -- read as .metadata.annotations.kubectl.kubernetes.io...
kubectl get pod web -o jsonpath='{.metadata.annotations.kubectl.kubernetes.io/last-applied-configuration}'

# RIGHT
kubectl get pod web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
```

**Escape each dot in the key with `\.`.** The slash needs no escaping.

This comes up constantly, because the fields you most want are named this way:

```bash
kubectl get node NODE -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}'
kubectl get sc NAME   -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
```

### 32.4 Ranges make it readable

```bash
kubectl get nodes -o jsonpath='{.items[*].metadata.name}{"\n"}'
```

```
devops-control-plane devops-worker devops-worker2
```

One line. Now with a loop:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.cpu}{"\n"}{end}'
```

```
devops-control-plane    8
devops-worker           8
devops-worker2          8
```

**The pattern to memorise:**

```
{range .items[*]}{.field}{"\t"}{.other}{"\n"}{end}
```

`"\n"` and `"\t"` are **inside braces and quoted** — outside braces they print as
the literal characters.

### 32.5 `custom-columns` is usually better

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,CPU:.status.capacity.cpu,VERSION:.status.nodeInfo.kubeletVersion
```

```
NODE                   CPU   VERSION
devops-control-plane   8     v1.31.4
devops-worker          8     v1.31.4
```

**Aligned columns and a header, with no loop.** Two differences from `jsonpath`:

- **Omit `.items[*]`** -- `custom-columns` assumes one row per item.
- Use `[*]` inside a field for a list: `IMAGES:.spec.containers[*].image`.

**Prefer `custom-columns` whenever the answer is a table**, and `jsonpath` when
it is a single value or needs piping.

### 32.6 `--sort-by` takes a JSONPath

```bash
kubectl get pods  --sort-by=.metadata.creationTimestamp
kubectl get nodes --sort-by=.status.capacity.cpu
kubectl get events --sort-by=.lastTimestamp
kubectl get pv    --sort-by=.spec.capacity.storage
```

**No braces, no `.items[*]`** — just the path within each item, the same
expression `custom-columns` takes.

**`kubectl get events --sort-by=.lastTimestamp` is the most useful sorted
command there is**, because events come back unordered and you almost always want
the most recent.

### 32.7 `go-template` for what JSONPath cannot do

```bash
kubectl get pods -o go-template='{{range .items}}{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
```

**JSONPath has filters but no conditionals, no arithmetic and no string
functions.** When you need `if` or `printf`, `go-template` is the escape hatch —
the same templating as [CKA 28](../28-helm/). Rarely needed, worth knowing
exists.

### 32.8 Quoting, on Windows and elsewhere

**This is a real problem and it wastes real time.**

| Shell | Wrap the expression in |
|---|---|
| bash, zsh, Git Bash | **single quotes** -- `'{.items[0].metadata.name}'` |
| PowerShell | **single quotes**; inner double quotes need care |
| cmd.exe | double quotes, with inner ones doubled -- avoid |

**The reliable escape from quoting problems is to put the query in a file:**

```bash
kubectl get nodes -o custom-columns-file=columns.txt
kubectl get nodes -o jsonpath-file=query.txt
```

`columns.txt`:

```
NODE              CPU
.metadata.name    .status.capacity.cpu
```

**On Windows, `custom-columns-file` is often the fastest route to a working
command** — there is no quoting at all.

### 32.9 The workflow

**Never guess a path.** The sequence, every time:

```bash
# 1. dump the object
kubectl get node devops-worker -o json > /tmp/n.json

# 2. find the field
jq '.status.capacity' /tmp/n.json
jq -r 'paths | join(".")' /tmp/n.json | grep -i cpu

# 3. write the query against the SAME shape
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.cpu}{"\n"}{end}'
```

**Step 3's shape must match step 1's.** If you explored a single object and then
query the plural form, the path needs `.items[*]` in front of it (32.2).

Without `jq`, `kubectl explain` gives you the field tree:

```bash
kubectl explain pod.spec --recursive | head -40
kubectl explain node.status.capacity
```

**`kubectl explain` is available in the exam and `jq` may not be.** Practise with
both.

---

## Part 2 - Hands-on lab

This assignment is **drills**. Reading it teaches you nothing; doing the twenty
tasks in fifteen minutes is the point.

```bash
kubectl config use-context kind-devops
kubectl apply -f solution/setup.yaml
kubectl -n cka32 rollout status deployment/web --timeout=120s
```

That creates a namespace with objects that have the awkward things real objects
have: **dotted annotation keys, multiple containers, named ports, resource
limits, node labels and a taint.**

### The drills

Open [solution/drills.md](solution/drills.md), work through it, and check your
answers against [solution/README.md](solution/README.md).

**Time yourself.** The target is **under 90 seconds per task** once you have the
syntax; the first few will take longer.

```bash
cat solution/drills.md
```

To see every task's expected output at once:

```bash
bash solution/check-drills.sh
```

**Run that only after attempting them.** It runs the reference answer for each
task and prints the result, so it is both an answer key and a way to confirm your
own command produces the same thing.

### Worked example — task 1

> *Print the name of every node, one per line.*

**Step 1: look at the shape.**

```bash
kubectl get nodes -o json | head -20
```

It is a `List` with an `items` array (32.2) — so every path starts `.items[*]`.

**Step 2: the naive version.**

```bash
kubectl get nodes -o jsonpath='{.items[*].metadata.name}'
```

```
devops-control-plane devops-worker devops-worker2
```

Right values, wrong shape — one line, space separated.

**Step 3: add the loop.**

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```

**Step 4: notice there was a shorter way.**

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers
kubectl get nodes -o name                                  # node/devops-worker
```

**All three are correct**, and in an exam the one you can type without thinking is
the right answer. `-o name` is shortest; `custom-columns` is the one that
generalises to two columns without changing shape.

### Cleanup

```bash
kubectl delete -f solution/setup.yaml --ignore-not-found
kubectl label node devops-worker cka32-disk- 2>/dev/null
kubectl taint node devops-worker cka32-role- 2>/dev/null
```

---

## Part 3 - Challenges

### C1 - Convert five commands

Rewrite each as a **single** `kubectl` command with no `grep`, `awk` or `jq`:

1. `kubectl get pods -o wide | grep devops-worker | awk '{print $1}'`
2. `kubectl get nodes -o yaml | grep -A3 capacity | grep cpu`
3. `kubectl get pods -o json | jq -r '.items[].spec.containers[].image' | sort -u`
4. `kubectl get svc | grep NodePort`
5. `kubectl get pods -A | grep -v Running | grep -v Completed`

Say which of the five is genuinely better as one command and which is better
left as a pipeline.

### C2 - Why is it empty?

Each of these returns nothing. Say why, and fix it:

```bash
kubectl get pods -o jsonpath='{.metadata.name}'
kubectl get node devops-worker -o jsonpath='{.items[0].status.capacity.cpu}'
kubectl get deploy web -n cka32 -o jsonpath='{.metadata.annotations.example.com/owner}'
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}\n{end}'
kubectl get pods -n cka32 -o jsonpath='{.items[?(@.metadata.labels.tier=='frontend')].metadata.name}'
```

### C3 - Pick the tool

For each, say whether you would use `jsonpath`, `custom-columns`, `--sort-by`,
`-o name`, `go-template` or a shell pipeline — and why:

1. Get one Service's ClusterIP into a shell variable.
2. Produce a table of every PVC with its size, class and status.
3. Delete every pod in a namespace whose phase is `Failed`.
4. Find the five most recently created pods in the cluster.
5. List every image in the cluster that comes from Docker Hub.

### C4 - The exam-day question

An exam task says: *"Find the pod in namespace `dev` with the highest CPU
request and write its name to `/opt/answer.txt`."*

1. Write it as one command.
2. What does JSONPath **not** let you do here, and how do you work around it?
3. Give a second solution using a different tool.
4. Which would you actually type under time pressure, and why?

### C5 - Build a diagnostic one-liner

Write a single command that outputs, for every pod in the cluster that is not
`Running`: its namespace, name, phase, node, and the reason from its first
container's state. Explain each part, and say what you would have to change if
some pods have no container statuses at all.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks that the setup objects exist, and then runs a representative query from
each category — a range, a filter, an escaped annotation key, a
`custom-columns` table, a `--sort-by`, a `custom-columns-file` and a
`go-template` — asserting that each returns the expected value rather than
nothing.

---

## Part 5 - Exam notes

**The dozen commands worth having in muscle memory**

```bash
# a single value
kubectl get svc web -o jsonpath='{.spec.clusterIP}'
kubectl get pod web -o jsonpath='{.status.podIP}'
kubectl get deploy web -o jsonpath='{.spec.replicas}'

# one per line
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'

# two columns
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu

# a filter
kubectl get pods -o jsonpath='{range .items[?(@.spec.nodeName=="node1")]}{.metadata.name}{"\n"}{end}'

# an escaped key
kubectl get node N -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}'

# sorting
kubectl get events --sort-by=.lastTimestamp
kubectl get pods --sort-by=.metadata.creationTimestamp

# a decoded Secret
kubectl get secret S -o jsonpath='{.data.password}' | base64 -d

# every image in the cluster
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,IMAGES:.spec.containers[*].image

# for piping
kubectl get pods -o name | xargs -n1 kubectl describe
```

**Faster than JSONPath, when they apply**

```bash
kubectl get pods -l tier=frontend                       # a label selector
kubectl get pods --field-selector=status.phase!=Running # a field selector
kubectl get pods -A --field-selector=spec.nodeName=node1
kubectl get pods -o wide                                # often already enough
```

**Reach for a selector before a filter.** `-l tier=frontend` is shorter than the
JSONPath equivalent, runs server-side, and cannot be mistyped into silence.

**Traps**

- **A single object has no `.items`; a list does.** The most common cause of
  empty output.
- **`{}` are required**, and text outside them is printed literally.
- **`\n` and `\t` must be inside braces and quoted**: `{"\n"}`.
- **Dots inside a key need `\.`** — annotations and labels always have them.
- **`custom-columns` omits `.items[*]`**; `jsonpath` requires it.
- **`--sort-by` takes a bare path**, with no braces and no `.items[*]`.
- **Filters use `==` with double quotes inside single quotes**, and JSONPath
  cannot compare numbers — use `go-template` for that.
- **An empty result is not an error.** `kubectl` exits 0, which is why a typo is
  silent.
- **Quoting differs by shell.** `custom-columns-file` and `jsonpath-file` sidestep
  it entirely.
- **`kubectl explain --recursive` is in the exam**; `jq` may not be.

---

**Previous:** [CKA 31 — Troubleshooting: Three Failure Domains](../31-troubleshooting/)
**Next: CKA 33 — Mock Exam Task Bank** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
