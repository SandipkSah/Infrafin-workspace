# PostgreSQL HA Cluster — Test & Acceptance Plan

**Purpose:** verify, independently and repeatably, that the cluster actually does what it claims to
do — survives a database crash automatically, survives losing a referee, and refuses unauthenticated
traffic. Anyone with SSH access to the three hosts can run this without needing the history of how it
was built.

## How to use this

- Run the sections **in order**. A–C are read-only or self-cleaning — safe to run anytime, in any
  order, with zero risk to anything.
- **Section D is the real test and is deliberately disruptive** — it stops the live primary database.
  It recovers itself automatically in under a minute, but don't run it outside a window where a
  ~30-second interruption is acceptable, and don't run it casually while skimming the document.
- Each check has a **Pass/Fail** box. Tick it after confirming the actual output matches what's
  described — don't just run the command and assume.
- A sign-off block is at the end for whoever runs this to record the result.
- **Every command below is labeled `[on db1]`, `[on db2]`, `[on prod3]`, or `[from your Mac / any
  external client]`.** A few commands only exist on one side — e.g. `psql` isn't installed on the bare
  hosts, only inside the containers — running a Mac-labeled command over SSH on a server will just fail
  with "command not found." Check the label before running.
- **Roles move.** Section C deliberately swaps which node is primary, and Section D does again. From
  that point on, don't assume "the primary" means a specific hostname — run `patronictl list` first
  each time and use whichever member it currently shows as `Leader`. The service name to `exec` into is
  always `pg1` on db1 and `pg2` on db2, regardless of which one is currently leading.
- **If pasting commands into an interactive shell (not a script), don't include a line that starts with
  `#`** — some shells (zsh, by default) don't treat that as a comment in an interactive session and will
  error with `command not found: #`. Harmless if it happens, just re-run the actual command on its own.

### Quick reference

| Host | Address | Role |
|---|---|---|
| db1 | `10.10.10.20` | database + etcd voter |
| db2 | `10.10.10.21` | database + etcd voter |
| prod3 | `10.10.10.13` | etcd voter only (no database) |
| **Virtual IP** | `10.10.10.18` | always points at whichever node is primary |

Cluster name: `amfcluster`. Postgres port `15432`. All commands below assume you're in the deploy
directory of whichever host you're on (`/srv/docker/pg-cluster-instance-{1,2,3}/`) and prefixed with
`sudo` where the original setup required it.

---

## Section A — Is everything actually up? *(read-only, zero risk)*

**Why this matters:** before testing failure recovery, confirm there's nothing already broken.

**A1. All three referees present and healthy**
```bash
sudo docker compose exec etcd etcdctl \
  --endpoints=https://10.10.10.21:12379 --cacert=/certs/ca.crt \
  --cert=/certs/etcd2.client.crt --key=/certs/etcd2.client.key \
  member list -w table
```
Expected: **3 rows**, all `STATUS: started`, `IS LEARNER: false`.

```bash
sudo docker compose exec etcd etcdctl \
  --endpoints=https://10.10.10.21:12379 --cacert=/certs/ca.crt \
  --cert=/certs/etcd2.client.crt --key=/certs/etcd2.client.key \
  endpoint health --cluster
```
Expected: all 3 endpoints report `healthy`.

- [ ] **Pass** — 3 members, all healthy

**A2. Database roles are as expected**
```bash
sudo docker compose exec pg1 patronictl list
```
Expected: exactly **one `Leader` (running)** and **one `Replica` (streaming)**, `Lag in MB: 0`.

- [ ] **Pass** — one leader, one streaming replica, zero lag

**A3. The virtual IP is on the current primary — and only there**

On whichever host `patronictl` showed as `Leader`:
```bash
ip addr show <its interface> | grep 10.10.10.18   # ens259f0 on db1, ens259f0np0 on db2
```
Expected: present. On the *other* database host, the same command should return **nothing**.

- [ ] **Pass** — VIP present on the leader only

---

## Section B — Does data actually move correctly? *(self-cleaning, near-zero risk)*

**Why this matters:** confirms replication is real and that the standby genuinely cannot be written to
— the core guarantee behind "one writer, no split-brain."

**Before you start:** every `psql` below connects as the `postgres` superuser and will prompt for a
password. Look it up first so you're not guessing at the prompt:
```bash
grep PGPASSWORD_SUPERUSER .env      # [on db1 or db2 — same value on both, must match]
```

**B1. Write on the primary**
```bash
sudo docker compose exec pg1 psql -h 127.0.0.1 -p 15432 -U postgres \
  -c "CREATE TABLE IF NOT EXISTS acceptance_test(id int); INSERT INTO acceptance_test VALUES (1);"
```
- [ ] **Pass** — insert succeeds

**B2. Same data visible on the standby**
```bash
sudo docker compose exec pg2 psql -h 127.0.0.1 -p 15432 -U postgres \
  -c "SELECT * FROM acceptance_test;"
```
Expected: the row from B1 is there. *(Run on whichever host is currently the replica — swap `pg1`/`pg2` if roles differ from Section A.)*

- [ ] **Pass** — row present on the standby

**B3. The standby refuses writes**
```bash
sudo docker compose exec pg2 psql -h 127.0.0.1 -p 15432 -U postgres \
  -c "INSERT INTO acceptance_test VALUES (2);"
```
Expected: **fails** with `ERROR: cannot execute INSERT in a read-only transaction`. This failure is the
correct, desired outcome — if this succeeds instead, that is a serious problem.

- [ ] **Pass** — write correctly rejected

**Cleanup:**
```bash
sudo docker compose exec pg1 psql -h 127.0.0.1 -p 15432 -U postgres -c "DROP TABLE acceptance_test;"
```

---

## Section C — Planned handover *(controlled, reversible, ~5s)*

**Why this matters:** proves the cluster can move leadership on purpose — e.g. for maintenance —
without losing a single write.

```bash
sudo docker compose exec pg1 patronictl switchover
```
Follow the prompt, confirm. Then:
```bash
sudo docker compose exec pg1 patronictl list
```
Expected: leadership has moved to the other node cleanly, both show healthy, `Lag in MB: 0`.

Check the VIP followed it:
```bash
ip addr show <interface of new leader> | grep 10.10.10.18
```

- [ ] **Pass** — roles swapped cleanly, VIP followed, no lag

*(Optional: run switchover again to move leadership back to where it started.)*

---

## Section D — ⚠️ Unplanned failure: does it actually recover on its own?

**This is the real test.** Everything above confirms the parts are healthy; this confirms the whole
point of the system — that a database crash requires no human action.

**What you're about to do:** forcibly stop the current primary's database process, exactly as if the
host had crashed. **Do not run this unless you're prepared for a ~30 second interruption right now.**

**D1. Note the current primary, then kill it**
```bash
sudo docker compose exec pg1 patronictl list       # note which is Leader
```
On whichever host is the **Leader**, start an actual stopwatch (phone, terminal, anything) the moment
you run this — the elapsed time to promotion is the one number worth walking away with from this whole
test plan, don't skip timing it:
```bash
sudo docker compose stop pg1        # or pg2 — whichever is currently Leader
```

**D2. Watch it recover — this is what you're timing**

From the *other* database host, poll every few seconds:
```bash
sudo docker compose exec pg2 patronictl list        # or pg1
```
The instant this shows the surviving node as **Leader, running**, stop the clock. Expected: roughly
30 seconds. Record the actual number in the sign-off at the end — "it recovered" and "it recovered in
27 seconds" are very different things to hand someone.

**D3. Confirm the virtual IP followed**
```bash
ip addr show <interface of new leader> | grep 10.10.10.18
ip addr show <interface of old (now dead) leader> | grep 10.10.10.18   # should be gone
```

**D4. Confirm a real client can still write — through the same address it always uses**

**[from your Mac / any external client]** — not the hosts themselves:
```bash
psql "host=10.10.10.18 port=15432 user=postgres sslmode=require" -c "select pg_is_in_recovery();"
```
Expected: `f` (false) — a writable primary, reached at the exact same address as before the failure.
**No connection string, DNS entry, or application config was touched to make this work.**

> `sslmode=require` is included deliberately — without it, the default `prefer` mode can produce a
> confusing *pair* of unrelated-looking errors on a single failed attempt (e.g. a password error
> immediately followed by a `pg_hba.conf rejects ... no encryption` line). If you see both at once,
> it's almost always just a mistyped password on the first (SSL) attempt — retry carefully rather than
> chasing the second line as a separate bug.

**D5. Bring the old primary back and confirm it rejoins safely**
```bash
sudo docker compose start pg1        # whichever you stopped in D1
```
Wait ~30s, then:
```bash
sudo docker compose exec pg1 patronictl list
```
Expected: the node you killed comes back as a **Replica, streaming**, `Lag in MB: 0` — **not** a second
leader. Two leaders at once would mean the safety design has failed; this must never happen.

- [ ] **Pass** — promotion happened automatically, timed at approximately ______ seconds
- [ ] **Pass** — virtual IP moved to the new primary and only the new primary
- [ ] **Pass** — a client at the same address could write immediately after
- [ ] **Pass** — the killed node rejoined as a replica, not a second leader

---

## Section E — Does losing a referee break anything? *(reversible, ~1 minute)*

**Why this matters:** there are three independent voters specifically so that losing *any one* of them
doesn't take the database down. This proves that design choice actually holds.

**E1. Stop exactly one etcd voter** — on **prod3** (the one with no database, safest to pick):
```bash
cd /srv/docker/pg-cluster-instance-3
sudo docker compose stop etcd
```

**E2. Confirm the database cluster notices nothing**
```bash
sudo docker compose exec pg1 patronictl list                 # [on db1 or db2]
psql "host=10.10.10.18 port=15432 user=postgres sslmode=require" -c "select 1;"   # [from your Mac]
```
Expected: everything behaves completely normally — no promotion, no read-only fencing, write still
works. Losing 1 of 3 voters must be a non-event.

> **`patronictl list` may print a connection-error line mentioning the voter you just stopped** before
> printing the (correct, healthy) table below it. That's Patroni trying all three configured etcd
> endpoints, failing against the one that's down, and falling back to the other two — the warning *is*
> the fallback working, not a failure. Judge this test by the table, not the noise above it.

**E3. Confirm the referees know they're down to 2**
```bash
sudo docker compose exec etcd etcdctl \
  --endpoints=https://10.10.10.21:12379 --cacert=/certs/ca.crt \
  --cert=/certs/etcd2.client.crt --key=/certs/etcd2.client.key \
  endpoint health --cluster
```
Expected: 2 of 3 report healthy, 1 (prod3) is unreachable — this is expected and fine.

> This command ends with a summary line — `Error: unhealthy cluster` — whenever *any* single endpoint
> fails, even just the one deliberately stopped. Read it literally: it means "not every endpoint is
> healthy," not "quorum is lost." The pass condition is the two `healthy` lines above it.

**E4. Restore it**
```bash
cd /srv/docker/pg-cluster-instance-3
sudo docker compose start etcd
```
Wait ~10s, re-run the health check from E3 — expect all 3 healthy again.

> **Do not stop a second voter at the same time as this test.** Losing 2 of 3 is a deliberately
> different, much more severe scenario (total loss of quorum) that is *not* part of routine
> acceptance testing — it is covered separately in the runbook's disaster-recovery section.

- [ ] **Pass** — database fully operational with 1 of 3 referees down
- [ ] **Pass** — referee cluster returned to 3/3 healthy after restart

---

## Section F — Is the system actually locked down, or just configured to look that way?

**Why this matters:** a security control that was never tested is a security control you don't
actually have. This proves the enforcement is real, not just present in a config file.

**F1. An unauthenticated client must be refused by the referee layer**

**[from your Mac or any host]** — attempt to reach etcd **without presenting a certificate**:
```bash
curl -sk https://10.10.10.21:12379/v3/kv/range -d '{"key":"AA=="}'; echo "curl exit=$?"
```
Expected: **no response body**, and a **non-zero exit code** (commonly `35`, an SSL handshake failure —
etcd refused the connection before ever reaching the HTTP layer, since no client certificate was
presented). If this prints real JSON data, that is a critical finding, not a pass.

> Always check the exit code here, not just the output. `curl -s` silences error messages, so empty
> output on its own is ambiguous — it could mean "cleanly refused" or "something else silently failed."
> The exit code removes the ambiguity.

- [ ] **Pass** — request without a certificate is refused (non-zero exit code, no data)

**F2. The database itself must refuse a bad credential**
```bash
PGPASSWORD=wrong-password psql "host=10.10.10.18 port=15432 user=postgres sslmode=require" -c "select 1;"
```
Expected: `psql: error: ... password authentication failed for user "postgres"`.

- [ ] **Pass** — incorrect credential rejected

---

## Sign-off

| Field | |
|---|---|
| Tested by | |
| Date | |
| Sections completed | A · B · C · D · E · F |
| Overall result | PASS / FAIL |
| Notes / anomalies observed | |

**If every box above is checked and Section D's timing was in the tens of seconds, not minutes, the
cluster does what it was built to do.** Anything unchecked, or any result that reads "row present"
where it should read "refused" (or vice versa), should be treated as a real finding — not noise — and
brought back before this cluster is trusted with anything that isn't test data.
