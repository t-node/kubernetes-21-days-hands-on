# Day 11 — Postgres with ConfigMaps & Secrets

**Time:** 75-90 minutes
**Prerequisites:** Days 09-10

The third tier arrives and the whole app comes alive. You run Postgres, seed the
real DevBoard schema from a ConfigMap, connect with `psql`, and watch the
backend stop crash-looping.

You also run it as a **Deployment with `emptyDir`** — both deliberately wrong,
so Days 14 and 15 can fix them with something you have actually felt.

---

## Part 1 - Concepts

### 11.1 Should a database run in Kubernetes at all?

A favourite senior interview question. Give a balanced answer.

**Against:** databases are stateful and Kubernetes was built for stateless
workloads. Cluster storage is often slower than local NVMe. Backups, restores,
failover, major-version upgrades and replication are already solved well by RDS
or Cloud SQL. A bad rescheduling decision can cost data.

**For:** operators (CloudNativePG, Zalando, Crunchy) now handle backup, failover
and upgrades competently. One deployment model for everything. On-prem or
multi-cloud, managed may not be an option. Dev and test environments are far
easier.

**The honest answer:** use the managed service in production if you can. If you
cannot, use a mature **operator**, never a hand-rolled StatefulSet. Learn to do
it by hand — as you are about to — so you understand what the operator does.

### 11.2 The official `postgres` image contract

Everything today depends on how that image behaves.

| Env var | Effect |
|---|---|
| `POSTGRES_PASSWORD` | **required**; the superuser password |
| `POSTGRES_USER` | superuser name; defaults to `postgres` |
| `POSTGRES_DB` | database created on first init; defaults to `$POSTGRES_USER` |
| `PGDATA` | data directory; defaults to `/var/lib/postgresql/data` |

And the initialisation rule, the source of most confusion:

> On startup the entrypoint checks whether `$PGDATA` is **empty**. If it is, it
> runs `initdb`, creates the user and database, then executes every `*.sql`,
> `*.sql.gz` and `*.sh` file in `/docker-entrypoint-initdb.d/` **in alphabetical
> order**. If `$PGDATA` already contains a database, **all of that is skipped.**

Two consequences to internalise:

1. Seed SQL runs **exactly once**, on a fresh volume. Change the ConfigMap and
   restart — nothing happens, because the directory is no longer empty.
2. Alphabetical ordering is why DevBoard names its files `01_schema.sql` and
   `02_seed.sql`. Do the same.

### 11.3 The PGDATA subdirectory trick

You will hit this on Day 14; better to know it now. Mount a PersistentVolume at
`/var/lib/postgresql/data` and many storage backends leave a `lost+found`
directory there. Postgres sees a **non-empty** directory and refuses:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

The standard fix is to put the data one level down:

```yaml
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
volumeMounts:
  - name: data
    mountPath: /var/lib/postgresql/data
```

The volume mounts at `data/`, Postgres initialises into `data/pgdata/`, which is
genuinely empty. Do it from the start.

### 11.4 Why a Deployment is the wrong shape for a database

You will use one today anyway, so the failure is concrete.

| Problem | Why it matters for a database |
|---|---|
| Random pod names (`postgres-6d4f...`) | no stable identity; a replica cannot know it is the primary |
| All replicas share one PVC (or none) | two postmasters on one data directory **corrupts it** |
| No ordering guarantees | replica 2 can start before replica 1 has initialised |
| Rolling updates kill pods in arbitrary order | a database wants ordered, one-at-a-time restarts |
| New pod IPs, no stable per-pod DNS | replication needs to address a specific peer |

With `replicas: 1` it mostly works — which is exactly why people ship it and get
hurt later. Scale it to 2 in Break It and watch.

### 11.5 The DevBoard schema

Straight from `app/devboard/init/postgres/`:

```sql
projects (id, name, description, owner_id, created_at)
tasks    (id, title, description, project_id -> projects(id),
          assignee_id, status, priority, due_date, created_at, updated_at)
```

with `CHECK` constraints on `status` (`todo`, `in_progress`, `blocked`, `done`)
and `priority` (`low`, `medium`, `high`), two indexes, and a trigger that keeps
`tasks.updated_at` current. The seed inserts 2 projects and 10 tasks.

That is a real schema with foreign keys, constraints and a trigger — not a toy
`key/value` table.

### 11.6 Today's data is not persistent, and that is the point

Postgres uses an `emptyDir` volume: it lives and dies with the pod. Delete the
pod, lose everything you added. Entirely intentional — Day 14 introduces
PersistentVolumes and you will *feel* the difference rather than be told.

### 11.7 Where each setting lives

```
ConfigMap devboard-config          Secret devboard-secrets
  POSTGRES_HOST: postgres            POSTGRES_PASSWORD
  POSTGRES_PORT: "5432"
  POSTGRES_DB:   devboard          ConfigMap postgres-init
  POSTGRES_USER: devboard            01_schema.sql
  POSTGRES_SSLMODE / PORT            02_seed.sql
```

**Both** the Postgres pod and the backend pod read the same ConfigMap and
Secret. One source of truth, so the app and the database can never disagree
about credentials.

Note the Service must be named **`postgres`**, because that is the value of
`POSTGRES_HOST` in the ConfigMap — and it matches the compose service name, so
the DSN you saw in `docker-compose.yml` transfers unchanged.

---

## Part 2 - Hands-on lab

### Step 1: Confirm the config objects exist

```bash
kubectl apply -f ../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f ../day-10-secrets/solution/01-secret.yaml

kubectl get configmap devboard-config -n devboard -o jsonpath='{.data}{"\n"}'
kubectl get secret devboard-secrets -n devboard
```

### Step 2: Turn the real SQL files into a ConfigMap

The nicest way — build it straight from the fetched source, so there is no
copy to drift:

```bash
kubectl create configmap postgres-init -n devboard \
  --from-file=app/devboard/init/postgres/ \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl describe configmap postgres-init -n devboard
```

`--from-file=<directory>` creates one key per file in it, named after the file.
Two keys: `01_schema.sql` and `02_seed.sql`.

> A committed copy is also in `solution/01-postgres-init-configmap.yaml` so the
> repo works even if you have not fetched the source. Generating it from the
> real files is better practice — one source of truth.

Read the SQL before you run it:

```bash
cat app/devboard/init/postgres/01_schema.sql
cat app/devboard/init/postgres/02_seed.sql
```

### Step 3: Deploy Postgres

```bash
kubectl apply -f solution/02-postgres-deployment.yaml
kubectl apply -f solution/03-postgres-service.yaml

kubectl get pods -n devboard -l app=postgres -w      # Ctrl-C on Running
kubectl logs -n devboard -l app=postgres --tail=40
```

Read the log in full the first time — the contract from 11.2 executing:

```
The files belonging to this database system will be owned by user "devboard".
creating directory /var/lib/postgresql/data/pgdata ... ok
...
/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/01_schema.sql
CREATE TABLE
CREATE TABLE
CREATE INDEX
CREATE INDEX
CREATE FUNCTION
CREATE TRIGGER
/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/02_seed.sql
INSERT 0 2
INSERT 0 10
...
database system is ready to accept connections
```

initdb, then your files in alphabetical order, then ready.

### Step 4: Connect with psql

```bash
kubectl exec -it -n devboard deploy/postgres -- psql -U devboard -d devboard
```

Inside psql:

```sql
\dt                       -- projects, tasks
\d tasks                  -- columns, constraints, indexes, the trigger

SELECT id, name FROM projects;
SELECT id, title, status, priority FROM tasks ORDER BY id LIMIT 5;
SELECT status, count(*) FROM tasks GROUP BY status ORDER BY 2 DESC;

-- prove the CHECK constraint is real
INSERT INTO tasks (title, project_id, status) VALUES ('bad', 1, 'nonsense');
-- ERROR: new row violates check constraint "tasks_status_check"

-- prove the trigger works
UPDATE tasks SET status='done' WHERE id=2;
SELECT id, status, created_at, updated_at FROM tasks WHERE id=2;
-- updated_at is now, created_at is not

\q
```

Scriptable one-liners:

```bash
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -c "SELECT id,title,status FROM tasks ORDER BY id;"

kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"     # 10
```

### Step 5: Verify the credentials came from your objects

```bash
kubectl exec -n devboard deploy/postgres -- env | grep POSTGRES_
```

`POSTGRES_PASSWORD` matches your Secret; `POSTGRES_USER` and `POSTGRES_DB` match
your ConfigMap. Now prove authentication is enforced, over the network, by
Service name:

```bash
kubectl run pg-client --rm -it -n devboard --image=postgres:16-alpine -- \
  psql -h postgres -U devboard -d devboard -c "select current_user, current_database();"
# password prompt: a wrong one fails, "devboard" works
```

It connected by the **Service name** `postgres` — cluster DNS from Day 06 doing
its job.

### Step 6: Watch the backend come alive

The backend has been CrashLooping since Day 08.

```bash
kubectl get pods -n devboard -l app=backend
kubectl rollout restart deployment/backend -n devboard
kubectl rollout status  deployment/backend -n devboard

kubectl logs -n devboard -l app=backend --tail=5
# [backend] connected to postgres
# [backend] listening on :8080

kubectl get endpoints backend -n devboard     # now populated
```

End to end:

```bash
kubectl port-forward -n devboard svc/backend 8080:8080 &
sleep 2
curl -s localhost:8080/health
curl -s localhost:8080/projects
curl -s localhost:8080/tasks | head -c 400; echo
curl -s -X POST localhost:8080/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"Created via the API","project_id":1,"status":"todo","priority":"high"}'
kill %1
```

Then open <http://localhost:30080>. **The Kanban board renders with real data**
— two projects, ten tasks in columns. Drag a card, create a task; it persists to
Postgres.

Three tiers, running on Kubernetes, built by you.

### Step 7: Prove the init scripts only run once

```bash
kubectl patch configmap postgres-init -n devboard --type=merge -p \
'{"data":{"03_extra.sql":"CREATE TABLE audit_log (id serial primary key, msg text);"}}'

kubectl rollout restart deployment/postgres -n devboard
kubectl rollout status  deployment/postgres -n devboard

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard -c "\dt"
```

`audit_log` **is** there — because `emptyDir` gave the new pod an empty volume,
so Postgres re-initialised from scratch. Now check what that cost you:

```bash
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
```

Back to 10 — the seed rows. The task you created through the API is **gone**.

That is `emptyDir`, and it is Day 14's entire motivation.

On a real PersistentVolume the opposite happens: your data survives and
`03_extra.sql` is silently ignored forever. Both behaviours bite people; know
which one you have.

```bash
kubectl create configmap postgres-init -n devboard \
  --from-file=app/devboard/init/postgres/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Validate

```bash
kubectl apply -f ../day-09-configmaps/solution/01-configmap.yaml
kubectl apply -f ../day-10-secrets/solution/01-secret.yaml
kubectl apply -f ../day-10-secrets/solution/02-backend-deployment.yaml
kubectl apply -f solution/
kubectl rollout status deployment/postgres -n devboard --timeout=120s

# 1. schema and seed data exist
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"        # 10
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM projects;"     # 2

# 2. the backend finally stays up
kubectl rollout restart deployment/backend -n devboard
kubectl rollout status  deployment/backend -n devboard --timeout=120s
kubectl get endpoints backend -n devboard                                 # populated

# 3. end to end through the browser path
curl -s http://localhost:30080/api/tasks | head -c 200; echo
curl -s http://localhost:30080/api/projects
```

Ready for Day 12 when you can:

1. Say exactly when `/docker-entrypoint-initdb.d/` runs and when it does not.
2. Explain the `PGDATA` subdirectory trick and the error it avoids.
3. Give three reasons a Deployment is wrong for a database.
4. Explain why the backend was CrashLooping and what changed.

---

## Break it

**A. Scale Postgres to 2 replicas.**

```bash
kubectl scale deployment postgres --replicas=2 -n devboard
kubectl get pods -n devboard -l app=postgres
```

Both run. Now think about it: the Service load balances between them, so half
your queries hit a **completely separate, independently initialised database**.
Prove it:

```bash
POD1=$(kubectl get pods -n devboard -l app=postgres -o name | head -1)
POD2=$(kubectl get pods -n devboard -l app=postgres -o name | tail -1)

kubectl exec -n devboard $POD1 -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('only in pod 1', 1);"

kubectl exec -n devboard $POD1 -- psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
kubectl exec -n devboard $POD2 -- psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
```

Different counts. Your API now returns inconsistent results depending on which
pod it hit. Refresh the UI a few times and watch tasks appear and disappear.

With a **shared** ReadWriteMany volume it is far worse: two postmasters on one
data directory means corruption, not just inconsistency.

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
```

**B. Delete the pod, lose the data.**

```bash
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('please survive', 1);"

kubectl delete pod -n devboard -l app=postgres
kubectl rollout status deployment/postgres -n devboard

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "SELECT * FROM tasks WHERE title='please survive';"
# (0 rows)
```

**C. Forget POSTGRES_PASSWORD.**

```bash
kubectl run pg-nopass -n devboard --image=postgres:16-alpine --restart=Never
sleep 5
kubectl logs pg-nopass -n devboard
# Error: Database is uninitialized and superuser password is not specified.
kubectl delete pod pg-nopass -n devboard
```

**D. Rotate the Secret and discover it changes nothing.**

```bash
kubectl patch secret devboard-secrets -n devboard \
  -p '{"stringData":{"POSTGRES_PASSWORD":"newpassword"}}'
kubectl rollout restart deployment/backend -n devboard
sleep 25
kubectl logs -n devboard -l app=backend --tail=5
# FATAL ping db: pq: password authentication failed for user "devboard"
```

Postgres is **unaffected** — it was initialised with the old password, which now
lives inside the database, and `POSTGRES_PASSWORD` is only read on first init.
Changing it on an already-initialised database does nothing. You must:

```bash
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -c "ALTER USER devboard PASSWORD 'newpassword';"
kubectl rollout restart deployment/backend -n devboard
```

...or just restore the Secret:

```bash
kubectl apply -f ../day-10-secrets/solution/01-secret.yaml
kubectl rollout restart deployment/backend -n devboard
```

This is exactly the rotation coordination problem from Day 10, section 10.x —
and now you have felt it.

---

## Interview questions

<details>
<summary><b>1. Should databases run in Kubernetes?</b></summary>

Prefer a managed service if one is available - RDS or Cloud SQL already solve
backup, restore, failover and major-version upgrades, which are the genuinely
hard parts. If you must self-host, use a mature operator such as CloudNativePG
rather than a hand-written StatefulSet, because the operator encodes the
failover and backup logic. Hand-rolling is fine for dev and for learning.
</details>

<details>
<summary><b>2. Why is a Deployment wrong for a database?</b></summary>

Pods get random names and no stable identity, so a replica cannot know which one
it is. There is no per-replica volume, so replicas either collide on one data
directory - which corrupts Postgres - or silently become separate databases.
There is no start or stop ordering and no stable per-pod DNS name for
replication. StatefulSets provide all four.
</details>

<details>
<summary><b>3. When do docker-entrypoint-initdb.d scripts run?</b></summary>

Only when the data directory is empty at container start, which in practice
means only the first boot against a fresh volume, executed alphabetically. Any
later start with existing data skips them entirely. Schema changes after that
must go through a migration tool - Flyway, Liquibase, golang-migrate - typically
as a Job or an init container.
</details>

<details>
<summary><b>4. How do you handle schema migrations in Kubernetes?</b></summary>

A Job or init container running the migration tool before the new version
serves traffic, with a lock so only one runs at a time. Migrations must be
backwards compatible because a rolling update means old and new code run
simultaneously: expand, migrate, contract. Long-running migrations should be run
out of band so the deploy path stays fast.
</details>

<details>
<summary><b>5. Why set PGDATA to a subdirectory of the mount?</b></summary>

Many volume types create a `lost+found` directory at the mount root, and
Postgres refuses to initdb into a non-empty directory. Mounting at
`/var/lib/postgresql/data` while setting `PGDATA=/var/lib/postgresql/data/pgdata`
gives it a genuinely empty directory.
</details>

<details>
<summary><b>6. You changed POSTGRES_PASSWORD in the Secret and the app broke. Why?</b></summary>

That variable is only read during first-time initialisation; afterwards the
password lives inside the database. Updating the Secret changed what the client
sends but not what the server expects. Rotation requires ALTER USER inside
Postgres as well as the Secret update, coordinated so the application is never
presenting a credential the database has already changed - which usually means
supporting both briefly.
</details>

<details>
<summary><b>7. How would you back up Postgres in Kubernetes?</b></summary>

`pg_dump` from a CronJob to object storage is the simple answer and is adequate
for small databases. For anything real, continuous archiving - `pg_basebackup`
plus WAL shipping with pgBackRest or WAL-G - which gives point-in-time recovery.
CSI VolumeSnapshots are also usable with care about crash consistency. Whichever
you pick, test the restore; an untested backup is not a backup.
</details>

<details>
<summary><b>8. Two Postgres pods behind one Service. What happens?</b></summary>

If they have separate volumes you get two independent databases and the Service
randomly splits queries between them, so reads and writes disagree
non-deterministically - data appears and disappears. If they share one
ReadWriteMany volume it is worse: two postmasters on one data directory corrupt
it. Neither is replication; real replication needs distinct primary and replica
roles, which is what a StatefulSet plus an operator provides.
</details>

---

## Cheat card

```bash
# psql inside the pod
kubectl exec -it -n devboard deploy/postgres -- psql -U devboard -d devboard
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -c "SELECT id,title,status FROM tasks;"
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"   # scriptable

# a throwaway client (tests DNS + auth from the network side)
kubectl run pg-client --rm -it -n devboard --image=postgres:16-alpine -- \
  psql -h postgres -U devboard -d devboard

# from your laptop
kubectl port-forward -n devboard svc/postgres 5432:5432
# then: psql -h localhost -U devboard -d devboard

# regenerate the init ConfigMap from the real files
kubectl create configmap postgres-init -n devboard \
  --from-file=app/devboard/init/postgres/ --dry-run=client -o yaml | kubectl apply -f -

kubectl logs -n devboard -l app=postgres --tail=50
```

psql: `\l` databases, `\dt` tables, `\d tasks` describe, `\du` roles,
`\conninfo`, `\q` quit.

---

**Next: [Day 12 - Wire the three-tier app together](../day-12-wire-the-three-tier-app/)**
