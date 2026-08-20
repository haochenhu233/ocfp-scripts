# Concourse 7.13.2 → 8.2.2 upgrade runbook — AWS RDS (external DB)

Context: Concourse **v8.0.0** switched resource-version hashing from md5 to sha256. This requires
a DB migration (`1747084615_switch_md5_to_sha256`) that **rewrites every row** of
`resource_config_versions` and drops/rebuilds its GIN index — the single expensive step in the
upgrade. This runbook takes it end-to-end: **rehearse → baseline → deploy → restore performance →
verify → unpause**, with one artifact directory so the pre/post comparison is a diff rather than a
guess.

**Scope: external AWS RDS only.** The kit's `external-db.yml` addon does
`- type: remove path: /instance_groups/name=db?` — there is **no `db/0` VM**, so nothing here uses
`bosh ssh db/0` or `df -h /var/vcap/store`. All database work is done **inside a `psql` session
connected to the RDS endpoint**: shell blocks are marked ```bash, and everything marked ```sql is
pasted straight into that open session.

**Target 8.2.2, never 8.0.0.** v8.0.0's migration mishandles JSON null values in
`resource_config_versions` (fixed in 8.0.1, commit `46127b3a6`). 8.1.0 additionally fixed the index
cleanup and the `rerun_of` down migration. 8.2.2 has all of it.

**Verified against:** concourse `v8.2.2` (migration SQL, `fly` command flags and
`flag/postgres_config.go` all read at the tag) and `concourse-genesis-kit` `v3.13.0`.

> **Background — why any of this is here.** The mechanics (hashing/canonicalisation, DDL vs DML,
> B-tree vs GIN indexes, transactions and lock levels, MVCC → `VACUUM` vs `ANALYZE`, and how the
> Concourse migration engine runs) are written up separately as a junior-friendly primer in the
> `genesis-community` knowledge store at `knowledge/concourse/postgres-md5-sha256-primer.md`.
> Read that if any step below feels like cargo-culting.

## Phase map

| Part | Phase | When | Time |
|---|---|---|---|
| 0 | Setup & connect to RDS | — | 5 min |
| **1** | **🔴 Rehearse on sbx + prod-scale timing** | days before | 2–4 h |
| 2–4 | Baseline capture (`pre`) | days before + again just before | 40 min |
| 5 | Go/no-go + window prep | at the window | 15 min |
| 6 | The deploy | window | ⏱️ from Part 1 |
| 7 | ⛔ Gate check | immediately after | 2 min |
| 8 | Restore performance (`ANALYZE`/`VACUUM`) | after gate | 10 min–2 h |
| 9 | Verify + diff vs baseline (`post`) | before unpausing | 20 min |
| 10 | Staggered unpause | end of window | 30 min |
| 11 | Day-after checks | +24 h | 10 min |

---

## Part 0 — Setup

### 0.1 Shell variables (for `fly` / `bosh` / `aws` / `genesis`)

```bash
export DEP=concourse                    # BOSH deployment name
export GENESIS_ENV=prod                 # genesis env name
export FLY_TARGET=my-concourse          # fly target
export RDS_ID=<your-rds-instance-id>    # RDS DBInstanceIdentifier
export LABEL=pre                        # "pre" now, "post" after the upgrade
export OUT="./cc-upgrade-$LABEL-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT" && echo "→ $OUT"
```

### 0.2 Connect to RDS — open this session and keep it open

```bash
# RDS CA bundle (kit defaults external_db_sslmode: verify-ca)
curl -o rds-ca-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

export PGPASSWORD="$(safe get secret/${GENESIS_ENV}/concourse/database/external:password)"

psql "host=<your-rds-endpoint>.rds.amazonaws.com \
      port=5432 dbname=atc user=atc \
      sslmode=verify-ca sslrootcert=rds-ca-bundle.pem"
```

**Everything marked ```sql from here on is pasted into this session.**

### 0.3 Session setup

```sql
\timing on
\x auto
\set ON_ERROR_STOP on
```

Handy meta-commands while you work:

| Command | Does |
|---|---|
| `\d resource_config_versions` | describe a table — columns, indexes, constraints |
| `\di` | list indexes |
| `\o file.txt` | send output to a file (`\o` alone to stop) |
| `` \o | tee file.txt `` | send output to a file **and** the screen |
| `\i file.sql` | run a SQL file |
| `\q` | quit |

### 0.4 Confirm connectivity and scale

```sql
SELECT version();
SELECT current_database(), current_user, inet_server_addr();
SELECT count(*) AS resource_config_versions FROM resource_config_versions;
```

```bash
fly -t "$FLY_TARGET" status && fly -t "$FLY_TARGET" teams
```

> ⚠️ You need visibility of **all teams**. If `fly teams` shows only one, log in as a `main`-team
> admin or the capture will be silently incomplete.

### 0.5 🔴 Timeout pre-check — this can silently kill the migration

Concourse sets **no** statement timeout (verified: `flag/postgres_config.go:34-70` sets only a dial
timeout). Any timeout therefore comes from your RDS **parameter group** or the `atc` **role** — and
will abort the long `UPDATE` mid-transaction.

```sql
SHOW statement_timeout;
SHOW idle_in_transaction_session_timeout;
SHOW lock_timeout;

SELECT name, setting, source FROM pg_settings
 WHERE name IN ('statement_timeout','idle_in_transaction_session_timeout','lock_timeout');

SELECT rolname, rolconfig FROM pg_roles WHERE rolname IN ('atc', current_user);
```

**They are not equally dangerous — read this table before changing anything:**

| Setting | What it kills | Risk to the migration | Acceptable value |
|---|---|---|---|
| **`statement_timeout`** | a statement that **runs** longer than the limit | 🔴 **HIGH — this is the one that kills the long `UPDATE`** | `0`, or comfortably > rehearsed duration |
| `idle_in_transaction_session_timeout` | a session sitting in state `idle in transaction` (BEGIN issued, nothing executing, client silent) | 🟢 **Effectively none** — during the `UPDATE` the backend is `active`, not idle. The engine runs the whole `.sql` file as **one** `tx.Exec` (`atc/db/migration/migration.go:379-421`), so the only idle-in-transaction gaps are microseconds of Go error-checking between calls. | anything ≳ a few minutes. **`1d` (86400000 ms, the common RDS default) is fine — leave it alone.** |
| `lock_timeout` | a statement waiting too long to **acquire a lock** | 🟡 Low (you pause pipelines first), but it fails *fast*: if a conflicting query holds a lock when the DDL wants `ACCESS EXCLUSIVE`, this errors immediately instead of waiting | `0` is safest |

❌ **Act only if `statement_timeout` is non-zero and shorter than your rehearsed migration
duration.** Fix in a custom parameter group (dynamic — no reboot), or per-role as the RDS master
user:

```sql
-- as the RDS master user; only if the table above says you need to
ALTER ROLE atc SET statement_timeout = 0;
ALTER ROLE atc SET lock_timeout = 0;
```

Confirm it took effect on a **new** connection (role settings apply at login):

```sql
-- reconnect, then:
SHOW statement_timeout;
```

### 0.6 pgcrypto — a **runtime** dependency in Concourse 8

`digest()` is called in live query paths (`atc/db/resource_cache_factory.go:80,103`,
`resource_config_scope.go:157,288,317`, `resource.go:421,454`), not only by the migration.

```sql
SELECT name, default_version, installed_version
  FROM pg_available_extensions WHERE name='pgcrypto';
SELECT extname, extnamespace::regnamespace AS schema
  FROM pg_extension WHERE extname='pgcrypto';
SELECT encode(digest('test','sha256'),'hex') AS must_return_a_hash;
```

If missing, the **RDS master user** (has `rds_superuser`) creates it — the `atc` role may not be
able to:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

---

## Part 1 — 🔴 Rehearse (do not skip)

Two rehearsals that answer **two different questions**. Neither substitutes for the other.

| | **1a — sbx dress rehearsal** | **1b — prod-scale timing** |
|---|---|---|
| Question | *Does the procedure work?* | *How long will it take on prod?* |
| Validates | commands, release pin, SQL, deploy rolls cleanly | ⏱️ **duration**, on real data volume |
| Runs against | the sandbox Concourse + its own RDS | a **throwaway RDS restored from a prod snapshot** |
| Prod impact | none | none — snapshot is read-only and non-disruptive |

> ⚠️ **Three different databases are in play across this runbook.** Know which one you're connected
> to at any moment:
>
> | Database | Used in | What happens to it |
> |---|---|---|
> | **prod RDS** | Part 0, Parts 2–11 | pre-checks + baseline (read-only until the Part 6 deploy) |
> | **sbx RDS** | Part 1a | the full procedure, end to end |
> | **`cc-rehearsal`** (throwaway, restored from a prod snapshot) | Part 1b | migration timed, then **deleted** |

### 1a. Full dress rehearsal on sbx — validates the *procedure*

Run **this entire runbook, Parts 2–11**, against sandbox. This is what a sandbox is for: proving
the steps, the release pin, the psql connection and the SQL all work.

```bash
export DEP=concourse-sbx GENESIS_ENV=sbx FLY_TARGET=sbx RDS_ID=<sbx-rds-id>
# ... then work through Parts 2-11 exactly as written ...
```

Record what broke in the procedure, fix this runbook, then do prod.

> ⚠️ **Sandbox timing is NOT prod timing.** Sbx almost certainly has far fewer pipelines, builds
> and resource versions. A 90-second sbx migration tells you *nothing* about prod duration. That's
> what 1b is for.

### 1b. Prod-scale timing — validates the *duration*

**What this is:** snapshot prod → restore that snapshot into a **temporary throwaway RDS instance**
→ run the real 8.2.2 migration against the copy with a stopwatch → delete the instance.
**Production is never touched.**

**Why you can't skip it and just use the sbx number:** sbx has a fraction of prod's pipelines and
resource versions. The migration's cost scales with rows in `resource_config_versions` and the size
of the GIN index rebuild, so a 90-second sbx run tells you nothing about prod.

**Why the number matters:** the kit sets `canary_watch_time: 1000-60000` — **60 seconds max**
(`manifests/concourse/base.yml:23`). The web VM cannot report healthy until the migration commits,
so if prod takes 8 minutes and you haven't raised that, **BOSH fails the canary and aborts the
deploy mid-upgrade**. This number is what you set it from (≥3×) and what sizes your window.

**Two things you get free from the same exercise:** proof that your snapshot actually restores
(that's your rollback path), and the post-migration bloat figures — so you know *before* the window
whether you'll need `VACUUM FULL`, and therefore whether the window needs an extra outage in it.

This is the single best use of RDS in the whole exercise.

```bash
aws rds create-db-snapshot --db-instance-identifier "$RDS_ID" \
  --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d)
aws rds wait db-snapshot-available --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier cc-rehearsal \
  --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d) \
  --db-instance-class <same-class-as-prod> --no-publicly-accessible
aws rds wait db-instance-available --db-instance-identifier cc-rehearsal
```

**Run the real migration with the real 8.2.2 binary, and time it:**

```bash
time concourse migrate --migrate-to-latest-version \
  --postgres-host=<rehearsal-endpoint>.rds.amazonaws.com --postgres-port=5432 \
  --postgres-user=<user> --postgres-password=<pw> --postgres-database=atc \
  --postgres-sslmode=require
```

Then connect to the rehearsal instance and capture the bloat you should expect afterwards:

```bash
psql "host=<rehearsal-endpoint>.rds.amazonaws.com port=5432 dbname=atc user=<user> sslmode=require"
```

```sql
SELECT relname, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','builds','resource_caches')
 ORDER BY n_dead_tup DESC;
```

```bash
aws rds delete-db-instance --db-instance-identifier cc-rehearsal --skip-final-snapshot
```

| Record | Value |
|---|---|
| ⏱️ **Migration duration (prod-scale)** | **_______ min** |
| `canary_watch_time` to set | **≥ 3× the above** |
| `VACUUM FULL` needed? | pct_dead > 50% → yes |
| Snapshot restores cleanly | ☐ proven |

- [ ] **Part 1 complete — duration recorded, procedure validated on sbx**

---

## Part 2 — Baseline: fly & BOSH capture

Pure shell — no DB access needed.

```bash
#!/usr/bin/env bash
set -uo pipefail
: "${FLY_TARGET:?}"; : "${DEP:?}"; : "${OUT:?}"
T="$FLY_TARGET"

echo "==> [1/7] version & topology"
fly -t "$T" curl /api/v1/info                        > "$OUT/00-info.json" 2>&1
bosh -d "$DEP" instances --ps                        > "$OUT/01-bosh-instances.txt" 2>&1
bosh -d "$DEP" releases                              > "$OUT/02-bosh-releases.txt" 2>&1
fly -t "$T" workers --details --json                 > "$OUT/03-workers.json" 2>&1
fly -t "$T" teams --json                             > "$OUT/04-teams.json" 2>&1

echo "==> [2/7] pipeline inventory"
fly -t "$T" pipelines --all --include-archived --json > "$OUT/10-pipelines.json" 2>&1
jq -r '.[] | [.team_name,.name,(.paused|tostring),(.archived|tostring)] | @tsv' \
  "$OUT/10-pipelines.json" | sort > "$OUT/11-pipelines.tsv"

echo "==> [3/7] pipeline configs   <-- ALSO YOUR ROLLBACK ARTIFACT"
mkdir -p "$OUT/configs"
while IFS=$'\t' read -r team pipe _p _a; do
  [ -z "${pipe:-}" ] && continue
  fly -t "$T" get-pipeline --team "$team" -p "$pipe" > "$OUT/configs/${team}__${pipe}.yml" 2>/dev/null
done < "$OUT/11-pipelines.tsv"

echo "==> [4/7] job status   <-- WHAT IS ALREADY RED"
: > "$OUT/20-jobs-all.tsv"
while IFS=$'\t' read -r team pipe _p arch; do
  [ -z "${pipe:-}" ] || [ "$arch" = "true" ] && continue
  fly -t "$T" jobs --team "$team" -p "$pipe" --json 2>/dev/null \
    | jq -r --arg t "$team" --arg p "$pipe" \
      '.[]|[$t,$p,.name,(.paused|tostring),(.finished_build.status // "none")]|@tsv' \
    >> "$OUT/20-jobs-all.tsv"
done < "$OUT/11-pipelines.tsv"
sort -o "$OUT/20-jobs-all.tsv" "$OUT/20-jobs-all.tsv"
awk -F'\t' '$5!="succeeded" && $5!="none"' "$OUT/20-jobs-all.tsv" > "$OUT/21-jobs-not-green.tsv"

echo "==> [5/7] resources + pins"
: > "$OUT/30-resources-all.tsv"
while IFS=$'\t' read -r team pipe _p arch; do
  [ -z "${pipe:-}" ] || [ "$arch" = "true" ] && continue
  fly -t "$T" resources --team "$team" -p "$pipe" --json 2>/dev/null \
    | jq -r --arg t "$team" --arg p "$pipe" \
      '.[]|[$t,$p,.name,.type,(.pinned_version // {}|tostring)]|@tsv' \
    >> "$OUT/30-resources-all.tsv"
done < "$OUT/11-pipelines.tsv"
sort -o "$OUT/30-resources-all.tsv" "$OUT/30-resources-all.tsv"

echo "==> [6/7] builds & runtime footprint"
fly -t "$T" builds --all-teams --count 200 --json > "$OUT/40-builds-recent.json" 2>&1
fly -t "$T" containers --json > "$OUT/50-containers.json" 2>&1
fly -t "$T" volumes    --json > "$OUT/51-volumes.json"    2>&1

echo "==> [7/7] manifest"
genesis manifest "$GENESIS_ENV" > "$OUT/60-manifest.yml" 2>/dev/null

{ echo "captured:       $(date -u +%FT%TZ)"
  echo "concourse ver:  $(jq -r '.version // "?"' "$OUT/00-info.json")"
  echo "teams:          $(jq 'length' "$OUT/04-teams.json")"
  echo "pipelines:      $(wc -l < "$OUT/11-pipelines.tsv")"
  echo "configs saved:  $(ls -1 "$OUT"/configs/*.yml 2>/dev/null | wc -l)"
  echo "jobs:           $(wc -l < "$OUT/20-jobs-all.tsv")"
  echo "jobs NOT green: $(wc -l < "$OUT/21-jobs-not-green.tsv")"
  echo "resources:      $(wc -l < "$OUT/30-resources-all.tsv")"
  echo "containers:     $(jq 'length' "$OUT/50-containers.json")"
  echo "volumes:        $(jq 'length' "$OUT/51-volumes.json")"
} | tee "$OUT/SUMMARY.txt"
```

> 🔑 **`21-jobs-not-green.tsv` is the payoff.** With ~30 pipelines you *will* have pre-existing
> failures. This file is how you say "that was already red" with evidence instead of burning the
> window on it.

- [ ] **Part 2 complete**

---

## Part 3 — Baseline: database

In your psql session. `\o | tee` writes the file **and** shows you the output.

```sql
\o | tee 70-db-baseline-pre.txt

\echo '===== migration version ====='
SELECT version, direction, status, dirty, tstamp
  FROM migrations_history ORDER BY tstamp DESC LIMIT 5;

\echo '===== row counts ====='
          SELECT 'resource_config_versions'   AS t, count(*) FROM resource_config_versions
UNION ALL SELECT 'build_rcv_inputs',           count(*) FROM build_resource_config_version_inputs
UNION ALL SELECT 'build_rcv_outputs',          count(*) FROM build_resource_config_version_outputs
UNION ALL SELECT 'next_build_inputs',          count(*) FROM next_build_inputs
UNION ALL SELECT 'resource_caches',            count(*) FROM resource_caches
UNION ALL SELECT 'resource_disabled_versions', count(*) FROM resource_disabled_versions
UNION ALL SELECT 'resource_pins',              count(*) FROM resource_pins
UNION ALL SELECT 'builds',                     count(*) FROM builds
UNION ALL SELECT 'pipelines',                  count(*) FROM pipelines
UNION ALL SELECT 'resources',                  count(*) FROM resources
ORDER BY 1;

\echo '===== sizes & bloat ====='
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','build_resource_config_version_inputs',
                   'build_resource_config_version_outputs','next_build_inputs',
                   'resource_caches','resource_disabled_versions','builds')
 ORDER BY pg_total_relation_size(relid) DESC;

\echo '===== indexes on resource_config_versions (GIN gets dropped & rebuilt) ====='
SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
  FROM pg_indexes WHERE tablename='resource_config_versions' ORDER BY 1;

\echo '===== data shape (what broke v8.0.0 - non-zero is FINE on 8.2.2) ====='
SELECT count(*) FILTER (WHERE version IS NULL)                          AS null_versions,
       count(*) FILTER (WHERE jsonb_typeof(version::jsonb) <> 'object') AS non_object_versions
  FROM resource_config_versions;

\echo '===== PINNED versions (must survive identically) ====='
SELECT rp.resource_id, r.name AS resource, rp.version
  FROM resource_pins rp JOIN resources r ON r.id = rp.resource_id
 ORDER BY 1 LIMIT 200;

\echo '===== DISABLED versions (must survive identically) ====='
SELECT rdv.resource_id, r.name AS resource, rdv.version_md5
  FROM resource_disabled_versions rdv JOIN resources r ON r.id = rdv.resource_id
 ORDER BY 1,3 LIMIT 200;

\echo '===== FINGERPRINT newest 20 (must be byte-identical after) ====='
SELECT id, resource_config_scope_id, version_md5, version
  FROM resource_config_versions ORDER BY id DESC LIMIT 20;

\echo '===== FINGERPRINT oldest 20 (proves legacy history preserved) ====='
SELECT id, resource_config_scope_id, version_md5, version
  FROM resource_config_versions ORDER BY id ASC LIMIT 20;

\echo '===== pgcrypto (RUNTIME dependency in Concourse 8) ====='
SELECT extname, extnamespace::regnamespace AS schema FROM pg_extension WHERE extname='pgcrypto';

\echo '===== timeouts (non-zero will KILL the migration) ====='
SELECT name, setting, source FROM pg_settings
 WHERE name IN ('statement_timeout','idle_in_transaction_session_timeout','lock_timeout');

\echo '===== version & size ====='
SELECT version();
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;

\o
```

Then move the captured file into the artifact dir (from a **shell**, not psql):

```bash
mv 70-db-baseline-pre.txt "$OUT/"
```

**Storage headroom** — on RDS this is CloudWatch, not `df`:

```bash
aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].[AllocatedStorage,MaxAllocatedStorage,StorageType,MultiAZ]' --output table \
  | tee "$OUT/71-rds-storage.txt"

aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$RDS_ID" \
  --start-time "$(date -u -d '1 hour ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 300 --statistics Minimum --output table | tee -a "$OUT/71-rds-storage.txt"
```

You need **≈2× the `resource_config_versions` total size free** — the `UPDATE` doubles the table
while the GIN index rebuilds, all before `COMMIT`.

### 🔑 Write these three on paper

| Metric | Value | Must be after |
|---|---|---|
| `resource_config_versions` | ______ | **identical** |
| `resource_pins` | ______ | **identical** |
| `resource_disabled_versions` | ______ | **identical** |

- [ ] **Part 3 complete**

---

## Part 4 — Baseline: performance + breaking-change audit

In psql:

```sql
\o | tee 80-perf-baseline-pre.txt

EXPLAIN (ANALYZE, BUFFERS)
SELECT rcv.id, rcv.version FROM resource_config_versions rcv
 WHERE rcv.resource_config_scope_id =
       (SELECT resource_config_scope_id FROM resources WHERE resource_config_scope_id IS NOT NULL LIMIT 1)
 ORDER BY rcv.check_order DESC LIMIT 100;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM resource_config_versions WHERE version::jsonb @> '{}'::jsonb;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM build_resource_config_version_inputs i
  JOIN builds b ON b.id = i.build_id WHERE b.id > (SELECT max(id)-1000 FROM builds);

\o
```

```bash
mv 80-perf-baseline-pre.txt "$OUT/"
grep -E 'Execution Time|Planning Time|Seq Scan|Index Scan' "$OUT/80-perf-baseline-pre.txt"

# one real build, timed
time fly -t "$FLY_TARGET" trigger-job -j <pipeline>/<fast-representative-job> -w
```
→ baseline build duration: **_______**

**Breaking-change audit across all captured configs.** v8.0.0 also dropped `{{old_style}}` vars,
changed `put.inputs` to default to `detect`, made containerd the default runtime, always-enabled
pipeline instances / `across` / redact-secrets, and disallowed resources emitting empty versions:

```bash
cd "$OUT/configs"
echo "--- old-style {{vars}} (REMOVED in v8) ---";  grep -l '{{' *.yml 2>/dev/null || echo "  none ✅"
echo "--- put steps with inputs: (default → 'detect') ---"
  grep -l -E '^\s*put:' *.yml | while read -r f; do grep -q -E '^\s*inputs:' "$f" && echo "  review: $f"; done
echo "--- names containing '/' ---";  grep -nE '^\s*(name|put|get|task):\s*\S*/' *.yml 2>/dev/null || echo "  none ✅"
echo "--- literal private keys ---";  grep -l 'BEGIN.*PRIVATE KEY' *.yml 2>/dev/null || echo "  none ✅"
echo "--- custom resource_types ---"; grep -l -E '^resource_types:' *.yml 2>/dev/null | sed 's/^/  /'
cd - >/dev/null
```

- [ ] **Part 4 complete**

---

## Part 5 — Go / no-go + window prep

| Gate | Criterion |
|---|---|
| ✅ Rehearsed | Part 1a (sbx procedure) **and** 1b (prod-scale timing) both done |
| ✅ Backup | RDS snapshot taken **and** test-restored |
| ✅ Baseline | Parts 2–4 run; `SUMMARY.txt` + `21-jobs-not-green.tsv` reviewed |
| ✅ Target | Release pinned to **8.2.2** — never 8.0.0 |
| ✅ `canary_watch_time` | Raised from the kit default of **60 s** to ≥ 3× rehearsed duration |
| ✅ Timeouts | **`statement_timeout` = 0** (or > rehearsed duration) — Part 0.5. `idle_in_transaction_session_timeout` does **not** need changing |
| ✅ pgcrypto | Installed and callable (Part 0.6) |
| ✅ Storage | ≥ 2× `resource_config_versions` total size free; autoscaling headroom checked |
| ✅ Maintenance window | RDS `PreferredMaintenanceWindow` does **not** overlap — a Multi-AZ failover aborts the migration |
| ✅ Window | ≥ 3× rehearsed duration + restore time + buffer |
| ✅ People | Someone who can authorise rollback reachable throughout |

**Abort criteria, agreed in advance:** migration exceeds 2× rehearsed duration with no log progress;
free storage crosses 90% used; or Part 7 fails and the cause isn't clear within 30 minutes.

```bash
# notify users in the UI
fly -t "$FLY_TARGET" set-wall -m "Concourse upgrade until <HH:MM> — builds paused" --expire 4h

# record what was RUNNING (so you unpause back to exactly this state)
fly -t "$FLY_TARGET" pipelines --all --json \
  | jq -r '.[] | select(.paused==false) | [.team_name,.name] | @tsv' > "$OUT/90-was-running.tsv"
while IFS=$'\t' read -r team pipe; do
  fly -t "$FLY_TARGET" pause-pipeline --team "$team" -p "$pipe"
done < "$OUT/90-was-running.tsv"

# in-flight builds — let drain or abort
fly -t "$FLY_TARGET" builds --all-teams --count 50 --json \
  | jq -r '.[] | select(.status=="started") | "\(.pipeline_name)/\(.job_name) #\(.name)"'

# BACKUP — the fast rollback
aws rds create-db-snapshot --db-instance-identifier "$RDS_ID" \
  --db-snapshot-identifier cc-pre-822-$(date +%Y%m%d%H%M)
aws rds wait db-snapshot-available --db-snapshot-identifier cc-pre-822-$(date +%Y%m%d%H%M)

tar czf "cc-upgrade-pre-$(date +%F).tgz" "$OUT"    # keep the baseline safe
```

- [ ] **Part 5 complete — GO**

---

## Part 6 — The deploy

The kit (v3.13.0) pins concourse **7.13.2** in `manifests/releases/concourse.yml`, which
`hooks/blueprint.pm:26` actually uses. There is no 8.x kit release, so override in the env file.

> ⚠️ The kit's `docs/upgrade.md` suggests `releases: {concourse: {version: …}}` — **that form does
> not match the active manifest**, which is a top-level `releases:` *list*. Use the list form so
> spruce merges by `name`.

```yaml
# in your env .yml
releases:
- name: concourse
  version: "8.2.2"
  url:     https://bosh.io/d/github.com/concourse/concourse-bosh-release?v=8.2.2
  sha1:    <verify at https://bosh.io/releases/github.com/concourse/concourse-bosh-release?version=8.2.2>

# override the kit's 60s canary watch (manifests/concourse/base.yml:20-25)
update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 30000-<3x rehearsed duration in ms>
  update_watch_time: 30000-<same>
  serial: true
```

```bash
genesis manifest "$GENESIS_ENV" > "$OUT/61-manifest-new.yml"
diff "$OUT/60-manifest.yml" "$OUT/61-manifest-new.yml" | head -50   # sanity-check the diff
genesis deploy "$GENESIS_ENV"
```

**Watch the migration live.** There is no DB VM to tail — watch from inside psql instead. The ATC
sets `application_name=concourse` by default (`flag/postgres_config.go:21`):

```sql
SELECT pid, state, now()-xact_start AS running, wait_event_type, wait_event,
       left(query, 100) AS query
  FROM pg_stat_activity
 WHERE application_name = 'concourse' AND state <> 'idle'
 ORDER BY xact_start;
```

Repeat it every ~30 s (or `\watch 30` in psql). Also useful from the shell:

```bash
bosh -d "$DEP" ssh web/0 -c "sudo tail -f /var/vcap/sys/log/web/web.stdout.log" | grep -i migrat
```

**What runs:** 7 migrations, in ascending version order. Five are metadata-only and finish in
milliseconds; essentially all wall-clock time is #2 and #3.

| # | Version | Migration | Weight |
|---|---|---|---|
| 1 | 1746768931 | `add_signing_keys` | trivial |
| 2 | **1747084615** | **`switch_md5_to_sha256`** | 🔴 full table rewrite + GIN rebuild |
| 3 | **1765921815** | **`rerun_of_bigint`** | 🔴 4 index rebuilds on `builds` |
| 4 | 1771492499 | `add_disable_reruns` | trivial |
| 5 | 1772140118 | `next_check_time` | trivial |
| 6 | 1773181582 | `add_user_data_to_pipelines` | trivial |
| 7 | 1776182280 | `add_ttl_to_task_caches` | trivial |

- [ ] **Part 6 complete**

---

## Part 7 — ⛔ Gate check (2 min)

**Do not run `ANALYZE`/`VACUUM` and do not unpause until this passes.**

```sql
SELECT version, direction, status, dirty, tstamp
  FROM migrations_history ORDER BY tstamp DESC LIMIT 10;
```

✅ Top row: `version = 1776182280`, `direction = up`, `status = passed`, `dirty = f`

```sql
SELECT version, status, dirty, tstamp FROM migrations_history
 WHERE version IN (1747084615, 1765921815) ORDER BY tstamp;
```

✅ One `passed` row each. (A `failed` row followed by a `passed` row means it was retried
successfully — that's fine.)

```bash
bosh -d "$DEP" instances --ps | grep -E 'web|worker'
fly -t "$FLY_TARGET" workers
```

❌ Anything wrong → [Appendix A](#appendix-a--failure-triage). **Stop here.**

- [ ] **Gate passed**

---

## Part 8 — Restore performance

### 8.1 `ANALYZE` — 🔴 mandatory

Refreshes the planner statistics the rewrite invalidated. Safe on a live system, touches no data.
Skipping this is the #1 cause of "Concourse is slow after the upgrade" — the migration authors hit
it hard enough to hardcode `ANALYZE builds;` into the `rerun_of` migration with the comment
*"query plans were severly inefficient"*.

```sql
ANALYZE resource_config_versions;
ANALYZE build_resource_config_version_inputs;
ANALYZE build_resource_config_version_outputs;
ANALYZE next_build_inputs;
ANALYZE resource_caches;
ANALYZE resource_disabled_versions;
ANALYZE builds;
```

### 8.2 Measure bloat, then decide

```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','build_resource_config_version_inputs',
                   'build_resource_config_version_outputs','next_build_inputs',
                   'resource_caches','resource_disabled_versions','builds')
 ORDER BY n_dead_tup DESC;
```

| `pct_dead` on `resource_config_versions` | Action |
|---|---|
| **< 20%** | ✅ done — go to Part 9 |
| **20–50%** | `VACUUM` (online, safe) — 8.3a |
| **> 50%** or storage pressure | `VACUUM FULL` (⚠️ outage) or `pg_repack` (online) — 8.3b |

#### 8.3a — `VACUUM` (online, no outage)

Marks dead space reusable in place. Reads and writes continue normally.

```sql
VACUUM (VERBOSE) resource_config_versions;
VACUUM (VERBOSE) build_resource_config_version_inputs;
VACUUM (VERBOSE) build_resource_config_version_outputs;
VACUUM (VERBOSE) next_build_inputs;
VACUUM (VERBOSE) resource_caches;
VACUUM (VERBOSE) resource_disabled_versions;
```

#### 8.3b — `VACUUM FULL` ⚠️ requires an outage

> `ACCESS EXCLUSIVE` lock — Concourse fully blocked on that table — and needs ~2× the table size
> free. Web is already running by now, so **stop it first**.
>
> 💡 On RDS, `pg_repack` is available and does the same job **online**. Prefer it if you cannot
> take the outage. Also note RDS does not return freed storage to your account — you only regain
> space *inside* the allocated volume.

```bash
bosh -d "$DEP" stop web --skip-drain
bosh -d "$DEP" instances --ps | grep web
```

```sql
VACUUM FULL ANALYZE resource_config_versions;
VACUUM FULL ANALYZE build_resource_config_version_inputs;
VACUUM FULL ANALYZE build_resource_config_version_outputs;
VACUUM FULL ANALYZE next_build_inputs;
VACUUM FULL ANALYZE resource_caches;
VACUUM FULL ANALYZE resource_disabled_versions;

-- confirm the space came back
SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables WHERE relname='resource_config_versions';
```

```bash
bosh -d "$DEP" start web
bosh -d "$DEP" instances --ps | grep web
```

> `builds` is usually the largest table but was only *index*-rebuilt, not row-rewritten —
> `VACUUM FULL` on it is normally not worth the time. `ANALYZE builds` in 8.1 covered what matters.

- [ ] **Part 8 complete**

---

## Part 9 — Verify + diff against baseline

### 9.1 Re-run the captures as `post`

```bash
export LABEL=post
export OUT_POST="./cc-upgrade-post-$(date +%Y%m%d-%H%M)"
export OUT_PRE="./cc-upgrade-pre-<timestamp>"      # ← your Part 2 directory
export OUT="$OUT_POST"; mkdir -p "$OUT"
# re-run the Part 2 shell script
```

Re-run the **Part 3** and **Part 4** SQL in psql, changing the output filenames:

```sql
\o | tee 70-db-baseline-post.txt
-- ... paste the same Part 3 block ...
\o
```

```bash
mv 70-db-baseline-post.txt 80-perf-baseline-post.txt "$OUT/"
```

### 9.2 Diff

```bash
echo "### summary";        diff "$OUT_PRE/SUMMARY.txt"           "$OUT_POST/SUMMARY.txt"
echo "### pipelines";      diff "$OUT_PRE/11-pipelines.tsv"      "$OUT_POST/11-pipelines.tsv"
echo "### configs";        diff -rq "$OUT_PRE/configs"           "$OUT_POST/configs"
echo "### resources+pins"; diff "$OUT_PRE/30-resources-all.tsv"  "$OUT_POST/30-resources-all.tsv"
echo "### not-green";      diff "$OUT_PRE/21-jobs-not-green.tsv" "$OUT_POST/21-jobs-not-green.tsv"
echo "### db";             diff "$OUT_PRE/70-db-baseline-pre.txt" "$OUT_POST/70-db-baseline-post.txt"
```

| Diff | Expected | 🔴 Alarm if |
|---|---|---|
| `configs/` | **identical** | any change — the upgrade must not touch pipeline config |
| `11-pipelines.tsv` | **identical** | pipeline missing / renamed / newly archived |
| `30-resources-all.tsv` | **identical** incl. `pinned_version` | a pin disappeared |
| `21-jobs-not-green.tsv` | **identical** | *new* entries = upgrade-caused. Pre-existing ones are **not today's problem** |
| DB: `resource_config_versions`, `resource_pins`, `resource_disabled_versions` counts | **identical** | any change |
| DB: fingerprint oldest/newest 20 — `version_md5` + `version` | **byte-identical** | any change — the migration must *preserve* md5 and only *add* sha256 |
| DB: `version_sha256` column | now present, `NOT NULL` | any NULLs |
| `resource_caches` count | may change | fine — expected cache churn |
| Containers / volumes | may differ | fine — workers re-fetch after the digest change |
| perf `Execution Time` | comparable to pre | ≫ slower ⇒ re-run `ANALYZE` |

### 9.3 Schema & data checks

```sql
\echo '-- every row backfilled (MUST be 0)'
SELECT count(*) AS must_be_zero FROM resource_config_versions WHERE version_sha256 IS NULL;

\echo '-- legacy kept md5; new rows will not have one'
SELECT count(*) FILTER (WHERE version_md5 IS NOT NULL) AS legacy,
       count(*) FILTER (WHERE version_md5 IS NULL)     AS new_rows
  FROM resource_config_versions;

\echo '-- exactly 5 tables renamed'
SELECT table_name FROM information_schema.columns
 WHERE column_name='version_digest' ORDER BY 1;

\echo '-- indexes rebuilt'
SELECT indexname FROM pg_indexes WHERE tablename='resource_config_versions' ORDER BY 1;

\echo '-- temp constraint cleaned up (MUST be 0)'
SELECT count(*) AS must_be_zero FROM pg_constraint WHERE conname='temporary_digest_not_null';

\echo '-- pgcrypto still callable (RUNTIME dependency)'
SELECT encode(digest('test','sha256'),'hex') AS must_return_a_hash;

\echo '-- HASHING IS CORRECT: recompute 1000 rows (MUST be 0 mismatches)'
WITH s AS (SELECT id, version, version_sha256 FROM resource_config_versions LIMIT 1000),
j AS (SELECT s.id, s.version_sha256,
        COALESCE('{'||string_agg('"'||kv.key||'":"'||kv.value||'"', ',' ORDER BY kv.key)||'}','{}') js
        FROM s LEFT JOIN jsonb_each_text(jsonb_coalesce_empty(s.version::jsonb)) kv ON true
       GROUP BY s.id, s.version_sha256)
SELECT count(*) AS mismatches_must_be_zero FROM j
 WHERE version_sha256 <> encode(digest(js,'sha256'),'hex');

\echo '-- new versions written as sha256: newest rows should be NULL / 64'
SELECT id, length(version_md5) AS md5_len, length(version_sha256) AS sha_len
  FROM resource_config_versions ORDER BY id DESC LIMIT 5;
```

✅ Every `must_be_zero` returns `0`; the recompute returns `0` mismatches.

### 9.4 Functional

```bash
fly -t "$FLY_TARGET" workers                                    # registered, versions match
fly -t "$FLY_TARGET" resource-versions -r <pipeline>/<resource> | head -20   # history survived
fly -t "$FLY_TARGET" check-resource -r <pipeline>/<resource>
```

Open a **pre-upgrade** build in the UI — its inputs/outputs must still resolve (exercises the
`IN (version_md5, version_sha256)` compatibility joins directly). Confirm a previously pinned
resource still shows pinned, and a disabled version still shows disabled. These two are the
highest-signal checks: they are what would break if the md5 fallback were not working.

- [ ] **Part 9 complete — verified**

---

## Part 10 — Staggered unpause

> ⚠️ **Not all at once.** `resource_caches` keeps md5 digests but lookups are sha256-only
> (`atc/db/resource_cache_factory.go:80`, no fallback), so every previously-cached version misses
> once and re-downloads. Unpausing 30 pipelines simultaneously stampedes your workers.

```sql
SELECT count(*) AS caches_to_be_refetched FROM resource_caches;
```

```bash
# 1. one representative pipeline
fly -t "$FLY_TARGET" unpause-pipeline --team <team> -p <pipeline>
fly -t "$FLY_TARGET" trigger-job -j <pipeline>/<job> -w     # 1st run re-downloads — NORMAL
fly -t "$FLY_TARGET" trigger-job -j <pipeline>/<job> -w     # 2nd MUST hit cache — proves reuse

# 2. then batches, from the was-running list (restores the exact prior state)
head -5 "$OUT_PRE/90-was-running.tsv" | while IFS=$'\t' read -r team pipe; do
  fly -t "$FLY_TARGET" unpause-pipeline --team "$team" -p "$pipe"
done
# watch worker load, then the rest:
tail -n +6 "$OUT_PRE/90-was-running.tsv" | while IFS=$'\t' read -r team pipe; do
  fly -t "$FLY_TARGET" unpause-pipeline --team "$team" -p "$pipe"
done

fly -t "$FLY_TARGET" clear-wall
```

- [ ] **Part 10 complete**

---

## Part 11 — Day-after

```sql
-- old md5 caches being reaped? legacy_md5 should trend → 0 over ~a day
SELECT count(*) FILTER (WHERE length(version_digest)=32) AS legacy_md5,
       count(*) FILTER (WHERE length(version_digest)=64) AS new_sha256
  FROM resource_caches;

-- statistics fresh?
SELECT relname, last_analyze, last_autoanalyze, n_live_tup
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','builds','resource_caches') ORDER BY 1;

-- bloat settled?
SELECT relname, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','builds') ORDER BY 2 DESC;
```

```bash
bosh -d "$DEP" instances --ps
bosh -d "$DEP" logs web --num 200 | grep -iE 'migration|digest|error'

aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$RDS_ID" \
  --start-time "$(date -u -d '24 hours ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 3600 --statistics Minimum --output table

# re-run the Part 2 job-status capture and diff for any NEW red jobs after a full cycle
```

- [ ] **Upgrade complete** ✅ — keep the baseline tarball and the pre-upgrade snapshot for a week

---

## Appendix A — Failure triage

**First, the reassuring part:** each migration runs in its own transaction with its
`migrations_history` row committed inside it, so a *half-applied* migration is structurally
impossible. The realistic bad outcome is "rolled back, still on 7.13.2" — a schedule problem, not a
data problem.

```sql
SELECT version, direction, status, dirty, tstamp
  FROM migrations_history ORDER BY tstamp DESC LIMIT 20;
```

```bash
bosh -d "$DEP" logs web --num 500 | grep -iE 'migration|failed|error|rolled back'
```

| Symptom | Cause | Action |
|---|---|---|
| `status='failed'`, no later `passed` | Migration **rolled back cleanly**; schema untouched at previous version | Fix root cause below, redeploy — resumes from last committed version |
| BOSH canary timeout **but** `status='passed'` | Migration **succeeded**; BOSH stopped watching | Raise `canary_watch_time`, redeploy to finish rolling VMs |
| `canceling statement due to statement timeout` | 🔴 Parameter group / role timeout killed it | Set `statement_timeout=0` (Part 0.5), redeploy |
| `terminating connection due to administrator command` | 🔴 Multi-AZ failover or reboot mid-migration | Check RDS events; confirm no maintenance window overlap; redeploy |
| RDS storage-full / `could not extend file` | `UPDATE` doubles the table while GIN rebuilds | Grow allocated storage; prune build history + let GC run; redeploy |
| `permission denied to create extension "pgcrypto"` | `atc` role lacks rights | RDS **master** user runs `CREATE EXTENSION pgcrypto;`, redeploy |
| Second web VM appears hung | Advisory-lock retry loop (1 s), waiting on the canary | Normal — proceeds when the migration commits |
| Version stuck below `1776182280` | Web didn't start with the 8.2.2 binary | Check the deploy actually rolled |

> ⚠️ **Never hand-edit `migrations_history`.** `CurrentVersion()` already skips `status='failed'`
> rows, so re-running is normally safe. Editing makes schema and recorded version disagree.

**Rollback, increasing cost:**

1. *(automatic)* per-migration transaction rollback — free, always correct
2. Schema rollback to the last 7.13.2 migration, then redeploy with the 7.13.2 pin.
   **Best-effort** — 8.1.0 had to fix the sibling `rerun_of` down migration:
   ```bash
   concourse migrate --migrate-db-to-version 1666754000 \
     --postgres-host=<endpoint> --postgres-user=atc --postgres-password=<pw> \
     --postgres-database=atc --postgres-sslmode=verify-ca
   ```
3. **Restore the RDS snapshot** — the actually-correct rollback. *This is your plan.*
   ```bash
   aws rds restore-db-instance-from-db-snapshot \
     --db-instance-identifier <new-id> --db-snapshot-identifier cc-pre-822-<stamp> \
     --db-instance-class <same-as-prod>
   # then repoint external_db_host in the env file and redeploy
   ```
4. Pipeline configs mangled? `$OUT_PRE/configs/*.yml` is a complete `fly set-pipeline` restore set

---

## Appendix B — RDS operational notes

| Topic | Detail |
|---|---|
| 🔴 **`statement_timeout`** | Concourse sets none (`flag/postgres_config.go:34-70` — only a dial timeout), so any value comes from your **parameter group** or the `atc` role. A value shorter than the migration **kills it mid-transaction**. Set to `0` in a custom parameter group (dynamic — no reboot) or per-role. |
| 🟢 `idle_in_transaction_session_timeout` | **Not a risk — do not change it.** It only kills sessions that are `idle in transaction`; the migration is `active` throughout, and the engine runs the whole `.sql` file as one `tx.Exec`, so idle gaps are microseconds. `1d` (86400000 ms) is the common RDS default and is entirely fine. |
| **Multi-AZ failover** | A failover during the long transaction aborts it. Check `PreferredMaintenanceWindow` does not overlap your upgrade window. |
| **Storage** | CloudWatch `FreeStorageSpace`, not `df`. Need ~2× `resource_config_versions` total size free. If autoscaling is on, confirm `MaxAllocatedStorage` headroom; if off, pre-grow (online, but takes time and cannot be reversed). |
| **Backup = snapshot** | `create-db-snapshot` is far faster to take *and restore* than `pg_dump`. Take one immediately before the deploy — automated backups may not cover your exact pre-deploy moment. |
| **Rehearsal is cheap** | `restore-db-instance-from-db-snapshot` gives a prod-sized copy for timing (Part 1b), then delete it. |
| **pgcrypto** | Supported on RDS; the master user has `rds_superuser` and can create it. The `atc` role may not be able to. |
| **`VACUUM FULL`** | Works, but `ACCESS EXCLUSIVE` + 2× storage. `pg_repack` is available and does it online — prefer it if you can't take the outage. RDS does **not** return freed storage to the account; you regain space only *inside* the allocated volume. |
| **SSL** | Kit defaults `external_db_sslmode: verify-ca`. `psql` needs the RDS CA bundle: `curl -o rds-ca-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`. |
| **Watching the migration** | No DB VM to tail. Use `pg_stat_activity WHERE application_name='concourse'` (the ATC sets this by default), plus Performance Insights and CloudWatch `WriteIOPS` / `CPUUtilization`. |
| **Sandbox ≠ prod scale** | Sbx validates the *procedure*; only a prod-sized restore validates the *duration*. Do both (Part 1a + 1b). |

---

## Quick reference

```
0   CONNECT       psql "host=<rds> dbname=atc user=atc sslmode=verify-ca sslrootcert=..."
                  ⚠️ check statement_timeout = 0  AND  pgcrypto installed

1   REHEARSE 🔴   1a SBX           → full runbook end-to-end       = does the PROCEDURE work?
                  1b PROD SNAPSHOT → restore to THROWAWAY rds
                                   → `concourse migrate` → TIME IT = how LONG on prod?
                                   → delete throwaway. Prod untouched.
                  ⏱️ that duration → canary_watch_time (>=3x; kit default is only 60s!)

2-4 BASELINE      shell: pipelines, ALL configs, jobs-not-green, resources+pins
                  psql:  \o | tee 70-db-baseline-pre.txt  → counts/sizes/fingerprints
                  ✍️ write down: rcv / pins / disabled counts

5   GO-NO-GO      gates + abort thresholds + set-wall + pause (90-was-running.tsv) + SNAPSHOT

6   DEPLOY        env-file `releases:` LIST form + canary_watch_time
                  watch: pg_stat_activity WHERE application_name='concourse'

7   GATE ⛔       migrations_history → 1776182280 / up / passed / f      STOP IF NOT

8   RESTORE PERF  ANALYZE x7 (always) → measure pct_dead
                  20-50% → VACUUM   |   >50% → VACUUM FULL (stop web) or pg_repack (online)

9   VERIFY ✅     re-capture as post, diff. configs + pins + fingerprints MUST be identical.
                  recompute-1000-hashes → 0 mismatches

10  UNPAUSE       one pipeline, run TWICE (2nd must hit cache) → batches → clear-wall

11  DAY AFTER     legacy_md5 caches → 0, stats fresh, FreeStorageSpace stable, no NEW red jobs
```

**Three things people get wrong:** skipping `ANALYZE` (→ "it's slow now"); `VACUUM FULL` on a live
system (→ total outage); unpausing everything at once (→ cache-miss stampede).
