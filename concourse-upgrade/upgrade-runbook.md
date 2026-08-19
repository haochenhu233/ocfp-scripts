# Concourse 7.13.2 → 8.2.2 upgrade runbook (md5 → sha256 DB migration)

Context: Concourse **v8.0.0** switched resource-version hashing from md5 to sha256. This requires
a DB migration (`1747084615_switch_md5_to_sha256`) that **rewrites every row** of
`resource_config_versions` and drops/rebuilds its GIN index — the single expensive step in the
upgrade. This runbook takes it end-to-end: **rehearse → baseline → deploy → restore performance →
verify → unpause**, with one set of variables and one artifact directory so the pre/post comparison
is a diff rather than a guess.

**Target 8.2.2, never 8.0.0.** v8.0.0's migration mishandles JSON null values in
`resource_config_versions` (fixed in 8.0.1, commit `46127b3a6`). 8.1.0 additionally fixed the
index cleanup and the `rerun_of` down migration. 8.2.2 has all of it.

**Verified against:** concourse `v8.2.2` (migration SQL, `fly` command flags and
`flag/postgres_config.go` all read at the tag) and `concourse-genesis-kit` `v3.13.0`.

**Supports both DB topologies** — internal `postgres-release` (a `db/0` VM) and **external AWS
RDS**. The kit's `external-db.yml` addon *removes the `db` instance group entirely*, so on RDS
there is no `db/0` to `bosh ssh` into. Every DB command routes through a `$PSQL` helper set once in
Part 0. RDS-specific risks are consolidated in [Appendix B](#appendix-b--aws-rds-specifics).

> **Background — why any of this is here.** The mechanics (hashing/canonicalisation, DDL vs DML,
> B-tree vs GIN indexes, transactions and lock levels, MVCC → `VACUUM` vs `ANALYZE`, and how the
> Concourse migration engine runs) are written up separately as a junior-friendly primer in the
> `genesis-community` knowledge store at
> `knowledge/concourse/postgres-md5-sha256-primer.md`. Read that if any step below feels like
> cargo-culting.

## Phase map

| Part | Phase | When | Time |
|---|---|---|---|
| 0 | Setup & variables | — | 5 min |
| **1** | **🔴 Rehearse on sandbox + prod-scale timing** | days before | 2–4 h |
| 2–4 | Baseline capture (`LABEL=pre`) | days before + again just before | 40 min |
| 5 | Go/no-go + window prep | at the window | 15 min |
| 6 | The deploy | window | ⏱️ from Part 1 |
| 7 | ⛔ Gate check | immediately after | 2 min |
| 8 | Restore performance (`ANALYZE`/`VACUUM`) | after gate | 10 min–2 h |
| 9 | Verify + diff vs baseline (`LABEL=post`) | before unpausing | 20 min |
| 10 | Staggered unpause | end of window | 30 min |
| 11 | Day-after checks | +24 h | 10 min |

---

## Part 0 — Setup

```bash
export DEP=concourse                    # BOSH deployment name
export GENESIS_ENV=prod                 # genesis env name (often same as DEP)
export FLY_TARGET=my-concourse          # fly target
export LABEL=pre                        # "pre" now, "post" after the upgrade
export OUT="./cc-upgrade-$LABEL-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT" && echo "→ $OUT"
```

### Define DB access — pick ONE

```bash
# --- A) External / AWS RDS  (kit addon: external-db.yml — there is NO db/0 VM) ---
export PGHOST=<your-rds-endpoint>.rds.amazonaws.com
export PGPORT=5432
export PGUSER=atc
export PGDATABASE=atc
export PGPASSWORD="$(safe get secret/${GENESIS_ENV}/concourse/database/external:password)"
export PGSSLMODE=verify-ca
export PGSSLROOTCERT=./rds-ca-bundle.pem     # curl -o rds-ca-bundle.pem \
                                             #   https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
PSQL() { psql -v ON_ERROR_STOP=1 "$@"; }
```

```bash
# --- B) Internal postgres-release (db/0 VM exists) ---
PSQL() {
  local args=("$@") sqlfile=""
  for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "-f" ] && sqlfile="${args[$((i+1))]}"; done
  if [ -n "$sqlfile" ]; then
    bosh -d "$DEP" scp "$sqlfile" db/0:/tmp/_q.sql
    bosh -d "$DEP" ssh db/0 -c "sudo -u vcap /var/vcap/packages/postgres/bin/psql -U vcap -d atc -f /tmp/_q.sql"
  else
    bosh -d "$DEP" ssh db/0 -c "sudo -u vcap /var/vcap/packages/postgres/bin/psql -U vcap -d atc ${args[*]}"
  fi
}
```

Verify it works before going further:

```bash
PSQL -c "SELECT version();"
PSQL -c "SELECT count(*) FROM resource_config_versions;"
fly -t "$FLY_TARGET" status && fly -t "$FLY_TARGET" teams
```

> ⚠️ You need visibility of **all teams**. If `fly teams` shows only one, log in as a `main`-team
> admin or the capture will be silently incomplete.

### 🔴 RDS pre-check — run this now, it can silently kill the migration

Concourse sets **no** statement timeout (verified: `flag/postgres_config.go:34-70` sets only a dial
timeout). So any timeout comes from your RDS **parameter group** or the `atc` **role** — and will
abort the long `UPDATE` mid-transaction.

```bash
PSQL -c "SHOW statement_timeout;"
PSQL -c "SHOW idle_in_transaction_session_timeout;"
PSQL -c "SHOW lock_timeout;"
PSQL -c "SELECT rolname, rolconfig FROM pg_roles WHERE rolname IN ('atc',current_user);"
PSQL -c "SELECT name, setting, source FROM pg_settings
          WHERE name IN ('statement_timeout','idle_in_transaction_session_timeout','lock_timeout');"
```

✅ **Want:** all `0` (disabled). ❌ **Any non-zero value shorter than your rehearsed migration
duration will kill the migration.** Fix before deploying — see
[Appendix B](#appendix-b--aws-rds-specifics).

---

## Part 1 — 🔴 Rehearse (do not skip)

Use the sandbox for **two different things** — they answer different questions.

### 1a. Full dress rehearsal on sbx — validates the *procedure*

Run **this entire runbook, Parts 2–11**, against sandbox. This is what a sandbox is for: proving
the steps, the commands, the release pin, and your `$PSQL` helper all work.

```bash
export DEP=concourse-sbx GENESIS_ENV=sbx FLY_TARGET=sbx
# ... then work through Parts 2-11 exactly as written ...
```

Record what broke in the procedure, fix this runbook, then do prod.

> ⚠️ **Sandbox timing is NOT prod timing.** Sbx almost certainly has far fewer pipelines, builds
> and resource versions. A 90-second sbx migration tells you *nothing* about prod duration. That's
> what 1b is for.

### 1b. Prod-scale timing — validates the *duration*

Restore a **prod** snapshot to a scratch instance and time the real migration on real data volume.

```bash
# --- RDS ---
aws rds create-db-snapshot --db-instance-identifier <prod-rds-id> \
  --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d)
aws rds wait db-snapshot-available --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier cc-rehearsal \
  --db-snapshot-identifier cc-upgrade-rehearsal-$(date +%Y%m%d) \
  --db-instance-class <same-class-as-prod> --no-publicly-accessible
aws rds wait db-instance-available --db-instance-identifier cc-rehearsal
```

```bash
# --- or internal DB: dump and restore to a scratch postgres ---
bosh -d "$DEP" ssh db/0 -c \
  "sudo -i bash -c '/var/vcap/packages/postgres/bin/pg_dump -Fc -U vcap atc > /tmp/atc.dump'"
bosh -d "$DEP" scp db/0:/tmp/atc.dump ./atc-prod.dump
bosh -d "$DEP" ssh db/0 -c "sudo rm -f /tmp/atc.dump"
docker run -d --name pgrehearse -e POSTGRES_PASSWORD=pw -p 5433:5432 postgres:15   # match prod major version
createdb -h localhost -p 5433 -U postgres atc
pg_restore -h localhost -p 5433 -U postgres -d atc ./atc-prod.dump
```

**Run the real migration with the real 8.2.2 binary, and time it:**

```bash
time concourse migrate --migrate-to-latest-version \
  --postgres-host=<rehearsal-endpoint> --postgres-port=5432 \
  --postgres-user=<user> --postgres-password=<pw> --postgres-database=atc \
  --postgres-sslmode=require
```

Then capture the bloat you should expect afterwards, and tear it down:

```bash
psql -h <rehearsal-endpoint> -U <user> -d atc -c "
SELECT relname, n_dead_tup,
       round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables
 WHERE relname IN ('resource_config_versions','builds','resource_caches') ORDER BY 2 DESC;"

aws rds delete-db-instance --db-instance-identifier cc-rehearsal --skip-final-snapshot
# or: docker rm -f pgrehearse
```

| Record | Value |
|---|---|
| ⏱️ **Migration duration (prod-scale)** | **_______ min** |
| `canary_watch_time` to set | **≥ 3× the above** |
| `VACUUM FULL` needed? | pct_dead > 50% → yes |
| Prod backup restores cleanly | ☐ proven |

- [ ] **Part 1 complete — duration recorded, procedure validated on sbx**

---

## Part 2 — Baseline: fly & BOSH capture

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

```bash
cat > /tmp/baseline.sql <<'SQL'
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
SELECT name, installed_version FROM pg_available_extensions WHERE name='pgcrypto';
SELECT extname, extnamespace::regnamespace AS schema FROM pg_extension WHERE extname='pgcrypto';

\echo '===== timeouts (non-zero will KILL the migration) ====='
SELECT name, setting, source FROM pg_settings
 WHERE name IN ('statement_timeout','idle_in_transaction_session_timeout','lock_timeout');

\echo '===== version & size ====='
SELECT version();
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
SQL

PSQL -f /tmp/baseline.sql > "$OUT/70-db-baseline.txt" 2>&1
tail -50 "$OUT/70-db-baseline.txt"
```

**Free space** — note the topology difference:

```bash
# RDS: check allocated vs free storage
aws rds describe-db-instances --db-instance-identifier <rds-id> \
  --query 'DBInstances[0].[AllocatedStorage,MaxAllocatedStorage,StorageType]' --output table
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=<rds-id> \
  --start-time "$(date -u -d '1 hour ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 300 --statistics Minimum --output table

# internal DB:
bosh -d "$DEP" ssh db/0 -c "df -h /var/vcap/store"
```

### 🔑 Write these three on paper

| Metric | Value | Must be after |
|---|---|---|
| `resource_config_versions` | ______ | **identical** |
| `resource_pins` | ______ | **identical** |
| `resource_disabled_versions` | ______ | **identical** |

- [ ] **Part 3 complete**

---

## Part 4 — Baseline: performance + breaking-change audit

```bash
cat > /tmp/perf.sql <<'SQL'
\timing on
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
SQL

PSQL -f /tmp/perf.sql > "$OUT/80-perf-baseline.txt" 2>&1
grep -E 'Execution Time|Planning Time|Seq Scan|Index Scan' "$OUT/80-perf-baseline.txt"

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
| ✅ Backup | RDS snapshot taken **and** test-restored; or `pg_dump` test-restored |
| ✅ Baseline | Parts 2–4 run; `SUMMARY.txt` + `21-jobs-not-green.tsv` reviewed |
| ✅ Target | Release pinned to **8.2.2** — never 8.0.0 |
| ✅ `canary_watch_time` | Raised from the kit default of **60 s** to ≥ 3× rehearsed duration |
| ✅ Timeouts | `statement_timeout` / `idle_in_transaction_session_timeout` = 0 |
| ✅ pgcrypto | Installed and callable |
| ✅ Disk | ≥ 2× `resource_config_versions` total size free |
| ✅ Window | ≥ 3× rehearsed duration + restore time + buffer |
| ✅ People | Someone who can authorise rollback reachable throughout |

**Abort criteria, agreed in advance:** migration exceeds 2× rehearsed duration with no log progress;
disk crosses 90%; or Part 7 fails and the cause isn't clear within 30 minutes.

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

# BACKUP
aws rds create-db-snapshot --db-instance-identifier <rds-id> \
  --db-snapshot-identifier cc-pre-822-$(date +%Y%m%d%H%M)          # RDS
# or internal: pg_dump as in Part 1b

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

**Watch the migration live** (works on RDS too, where there's no VM to tail):

```bash
# from the web VM's logs
bosh -d "$DEP" ssh web/0 -c "sudo tail -f /var/vcap/sys/log/web/web.stdout.log" | grep -i migrat

# or from the DB side — application_name defaults to "concourse" (flag/postgres_config.go:21)
watch -n10 "psql -c \"SELECT pid, state, now()-xact_start AS running, \
  left(query,80) FROM pg_stat_activity WHERE application_name='concourse' \
  AND state<>'idle' ORDER BY xact_start;\""
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

```bash
PSQL -c "SELECT version, direction, status, dirty, tstamp
           FROM migrations_history ORDER BY tstamp DESC LIMIT 10;"
```

✅ Top row: `version = 1776182280`, `direction = up`, `status = passed`, `dirty = f`

```bash
PSQL -c "SELECT version, status, dirty, tstamp FROM migrations_history
          WHERE version IN (1747084615, 1765921815) ORDER BY tstamp;"
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

```bash
PSQL <<'SQL'
ANALYZE resource_config_versions;
ANALYZE build_resource_config_version_inputs;
ANALYZE build_resource_config_version_outputs;
ANALYZE next_build_inputs;
ANALYZE resource_caches;
ANALYZE resource_disabled_versions;
ANALYZE builds;
SQL
```

### 8.2 Measure bloat, then decide

```bash
PSQL -c "SELECT relname, n_live_tup, n_dead_tup,
  round(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),1) AS pct_dead,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables WHERE relname IN
  ('resource_config_versions','build_resource_config_version_inputs',
   'build_resource_config_version_outputs','next_build_inputs',
   'resource_caches','resource_disabled_versions','builds')
  ORDER BY n_dead_tup DESC;"
```

| `pct_dead` on `resource_config_versions` | Action |
|---|---|
| **< 20%** | ✅ done — go to Part 9 |
| **20–50%** | `VACUUM` (online, safe) — 8.3a |
| **> 50%** or disk pressure | `VACUUM FULL` (⚠️ outage) — 8.3b |

#### 8.3a — `VACUUM` (online, no outage)

```bash
PSQL <<'SQL'
VACUUM (VERBOSE) resource_config_versions;
VACUUM (VERBOSE) build_resource_config_version_inputs;
VACUUM (VERBOSE) build_resource_config_version_outputs;
VACUUM (VERBOSE) next_build_inputs;
VACUUM (VERBOSE) resource_caches;
VACUUM (VERBOSE) resource_disabled_versions;
SQL
```

#### 8.3b — `VACUUM FULL` ⚠️ requires an outage

> `ACCESS EXCLUSIVE` lock — Concourse fully blocked on that table — and needs ~2× the table size
> free. Web is already running by now, so **stop it first**. On RDS consider `pg_repack` instead
> (online, supported) — see [Appendix B](#appendix-b--aws-rds-specifics).

```bash
bosh -d "$DEP" stop web --skip-drain
bosh -d "$DEP" instances --ps | grep web

PSQL -c "VACUUM FULL ANALYZE resource_config_versions;"
PSQL <<'SQL'
VACUUM FULL ANALYZE build_resource_config_version_inputs;
VACUUM FULL ANALYZE build_resource_config_version_outputs;
VACUUM FULL ANALYZE next_build_inputs;
VACUUM FULL ANALYZE resource_caches;
VACUUM FULL ANALYZE resource_disabled_versions;
SQL

bosh -d "$DEP" start web
```

> `builds` is usually the largest table but was only *index*-rebuilt, not row-rewritten —
> `VACUUM FULL` on it is normally not worth the time. `ANALYZE builds` in 8.1 covered what matters.

- [ ] **Part 8 complete**

---

## Part 9 — Verify + diff against baseline

### 9.1 Re-run the capture as `post`

```bash
export LABEL=post
export OUT_POST="./cc-upgrade-post-$(date +%Y%m%d-%H%M)"
export OUT_PRE="./cc-upgrade-pre-<timestamp>"      # ← your Part 2 directory
export OUT="$OUT_POST"; mkdir -p "$OUT"
# re-run Part 2 script, Part 3 SQL, Part 4 perf SQL — identical commands
```

### 9.2 Diff

```bash
echo "### summary";        diff "$OUT_PRE/SUMMARY.txt"           "$OUT_POST/SUMMARY.txt"
echo "### pipelines";      diff "$OUT_PRE/11-pipelines.tsv"      "$OUT_POST/11-pipelines.tsv"
echo "### configs";        diff -rq "$OUT_PRE/configs"           "$OUT_POST/configs"
echo "### resources+pins"; diff "$OUT_PRE/30-resources-all.tsv"  "$OUT_POST/30-resources-all.tsv"
echo "### not-green";      diff "$OUT_PRE/21-jobs-not-green.tsv" "$OUT_POST/21-jobs-not-green.tsv"
echo "### db";             diff "$OUT_PRE/70-db-baseline.txt"    "$OUT_POST/70-db-baseline.txt"
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
| `80-perf-*.txt` execution times | comparable | ≫ slower ⇒ re-run `ANALYZE` |

### 9.3 Schema & data checks

```bash
PSQL <<'SQL'
\echo '-- every row backfilled (MUST be 0)'
SELECT count(*) AS must_be_zero FROM resource_config_versions WHERE version_sha256 IS NULL;

\echo '-- legacy kept md5; new rows will not have one'
SELECT count(*) FILTER (WHERE version_md5 IS NOT NULL) AS legacy,
       count(*) FILTER (WHERE version_md5 IS NULL)     AS new_rows
  FROM resource_config_versions;

\echo '-- exactly 5 tables renamed'
SELECT table_name FROM information_schema.columns WHERE column_name='version_digest' ORDER BY 1;

\echo '-- indexes rebuilt'
SELECT indexname FROM pg_indexes WHERE tablename='resource_config_versions' ORDER BY 1;

\echo '-- temp constraint cleaned up (MUST be 0)'
SELECT count(*) AS must_be_zero FROM pg_constraint WHERE conname='temporary_digest_not_null';

\echo '-- pgcrypto callable (RUNTIME dependency)'
SELECT encode(digest('test','sha256'),'hex') AS must_return_a_hash;

\echo '-- HASHING IS CORRECT: recompute 1000 rows (MUST be 0 mismatches)'
WITH s AS (SELECT id, version, version_sha256 FROM resource_config_versions LIMIT 1000),
j AS (SELECT s.id, s.version_sha256,
        COALESCE('{'||string_agg('"'||kv.key||'":"'||kv.value||'"', ',' ORDER BY kv.key)||'}','{}') js
        FROM s LEFT JOIN jsonb_each_text(jsonb_coalesce_empty(s.version::jsonb)) kv ON true
       GROUP BY s.id, s.version_sha256)
SELECT count(*) AS mismatches_must_be_zero FROM j
 WHERE version_sha256 <> encode(digest(js,'sha256'),'hex');
SQL
```

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

```bash
# new versions written as sha256
PSQL -c "SELECT id, length(version_md5) AS md5_len, length(version_sha256) AS sha_len
           FROM resource_config_versions ORDER BY id DESC LIMIT 5;"
# newest rows: md5_len NULL, sha_len 64
```

- [ ] **Part 9 complete — verified**

---

## Part 10 — Staggered unpause

> ⚠️ **Not all at once.** `resource_caches` keeps md5 digests but lookups are sha256-only
> (`atc/db/resource_cache_factory.go:80`, no fallback), so every previously-cached version misses
> once and re-downloads. Unpausing 30 pipelines simultaneously stampedes your workers.

```bash
PSQL -c "SELECT count(*) AS caches_to_be_refetched FROM resource_caches;"

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

```bash
# old md5 caches being reaped?
PSQL -c "SELECT count(*) FILTER (WHERE length(version_digest)=32) AS legacy_md5,
                count(*) FILTER (WHERE length(version_digest)=64) AS new_sha256
           FROM resource_caches;"
# legacy_md5 should trend → 0 over ~a day. If not, resource-cache GC isn't running.

PSQL -c "SELECT relname, last_analyze, last_autoanalyze FROM pg_stat_user_tables
           WHERE relname IN ('resource_config_versions','builds','resource_caches');"

bosh -d "$DEP" instances --ps
bosh -d "$DEP" logs web --num 200 | grep -iE 'migration|digest|error'
# re-run the Part 2 job-status capture and diff for any NEW red jobs after a full cycle
```

- [ ] **Upgrade complete** ✅ — keep the baseline tarball for a week

---

## Appendix A — Failure triage

```bash
bosh -d "$DEP" logs web --num 500 | grep -iE 'migration|failed|error|rolled back'
PSQL -c "SELECT version, direction, status, dirty, tstamp FROM migrations_history
           ORDER BY tstamp DESC LIMIT 20;"
```

**First, the reassuring part:** each migration runs in its own transaction with its
`migrations_history` row committed inside it, so a *half-applied* migration is structurally
impossible. The realistic bad outcome is "rolled back, still on 7.13.2" — a schedule problem, not
a data problem.

| Symptom | Cause | Action |
|---|---|---|
| `status='failed'`, no later `passed` | Migration **rolled back cleanly**; schema untouched at previous version | Fix root cause below, redeploy — resumes from last committed version |
| BOSH canary timeout **but** `status='passed'` | Migration **succeeded**; BOSH stopped watching | Raise `canary_watch_time`, redeploy to finish rolling VMs |
| `canceling statement due to statement timeout` | 🔴 RDS parameter group / role timeout killed it | Set `statement_timeout=0`, redeploy — [Appendix B](#appendix-b--aws-rds-specifics) |
| `No space left on device` / RDS storage-full | `UPDATE` doubles the table while GIN rebuilds | Grow storage; prune build history + let GC run; redeploy |
| `permission denied to create extension "pgcrypto"` | Locked-down DB | Superuser (RDS master) runs `CREATE EXTENSION pgcrypto;`, redeploy |
| Second web VM appears hung | Advisory-lock retry loop (1 s), waiting on the canary | Normal — proceeds when the migration commits |
| Version stuck below `1776182280` | Web didn't start with the 8.2.2 binary | Check the deploy actually rolled |

> ⚠️ **Never hand-edit `migrations_history`.** `CurrentVersion()` already skips `status='failed'`
> rows, so re-running is normally safe. Editing makes schema and recorded version disagree.

**Rollback, increasing cost:**
1. *(automatic)* per-migration transaction rollback — free, always correct
2. `concourse migrate --migrate-db-to-version 1666754000` (last 7.13.2 migration), then redeploy
   with the 7.13.2 pin. **Best-effort** — 8.1.0 had to fix the sibling `rerun_of` down migration
3. **Restore the RDS snapshot / `pg_dump`** — the actually-correct rollback. *This is your plan.*
4. Pipeline configs mangled? `$OUT_PRE/configs/*.yml` is a complete `fly set-pipeline` restore set

---

## Appendix B — AWS RDS specifics

| Topic | Detail |
|---|---|
| **No `db/0` VM** | `manifests/addons/external-db.yml` does `- type: remove path: /instance_groups/name=db?`. All `bosh ssh db/0` / `df -h /var/vcap/store` commands are invalid — use the RDS `$PSQL` helper (Part 0A) and CloudWatch. |
| 🔴 **`statement_timeout`** | Concourse sets none (`flag/postgres_config.go:34-70` — only a dial timeout), so any value comes from your **parameter group** or the `atc` role. A value shorter than the migration **kills it mid-transaction**. Set to `0` in a custom parameter group (dynamic — no reboot), or per-role: `ALTER ROLE atc SET statement_timeout = 0;`. Same for `idle_in_transaction_session_timeout`. |
| **Multi-AZ failover** | A failover during the long transaction aborts it. Avoid maintenance windows overlapping your upgrade; check `PreferredMaintenanceWindow`. |
| **Storage** | Watch CloudWatch `FreeStorageSpace`, not `df`. You need ~2× `resource_config_versions` total size free. If storage autoscaling is on, confirm `MaxAllocatedStorage` has headroom; if off, pre-grow it (storage scaling is online but takes time and can't be reversed). |
| **Backup = snapshot** | `aws rds create-db-snapshot` is far faster to take *and restore* than `pg_dump`. Take one immediately before the deploy. Note automated backups may not cover your exact pre-deploy moment. |
| **Rehearsal is cheap** | `restore-db-instance-from-db-snapshot` gives a prod-sized copy for timing (Part 1b), then delete it. This is the single best use of RDS here. |
| **pgcrypto** | Supported on RDS. The master user has `rds_superuser` and can `CREATE EXTENSION pgcrypto;`. The `atc` role may not be able to — pre-create it as master. |
| **`VACUUM FULL`** | Works, but `ACCESS EXCLUSIVE` + 2× storage. `pg_repack` is available on RDS and does it online — prefer it if you can't take the outage. Note RDS does **not** return freed storage to the account; you only regain space *inside* the allocated volume. |
| **SSL** | The kit defaults `external_db_sslmode: verify-ca`. For `psql` you need the RDS CA bundle: `curl -o rds-ca-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem` and `PGSSLROOTCERT=`. |
| **Watching the migration** | No VM to tail. Use `pg_stat_activity WHERE application_name='concourse'` (the ATC sets this by default) plus Performance Insights / CloudWatch `WriteIOPS` + `CPUUtilization`. |
| **Sandbox ≠ prod scale** | Sbx validates the *procedure*; only a prod-sized restore validates the *duration*. Do both (Part 1a + 1b). |

---

## Quick reference

```
1   REHEARSE 🔴   1a full runbook on SBX (procedure)
                  1b prod snapshot → scratch RDS → `concourse migrate` → TIME IT (duration)
                  → canary_watch_time = 3x
2-4 BASELINE      LABEL=pre: pipelines, ALL configs, jobs-not-green, resources+pins,
                  DB counts/sizes/fingerprints, perf, breaking-change audit
                  ✍️ write down: rcv / pins / disabled counts
5   GO-NO-GO      gates + abort thresholds + set-wall + pause (record 90-was-running.tsv) + SNAPSHOT
6   DEPLOY        env-file `releases:` LIST form + canary_watch_time; watch pg_stat_activity
7   GATE ⛔       migrations_history → 1776182280 / up / passed / f     STOP IF NOT
8   RESTORE PERF  ANALYZE x7 (always) → measure bloat → VACUUM / VACUUM FULL (stop web)
9   VERIFY ✅     LABEL=post, diff vs pre. configs + pins + fingerprints MUST be identical.
                  recompute-1000-hashes → 0 mismatches
10  UNPAUSE       one pipeline, run TWICE (2nd must hit cache) → batches → clear-wall
11  DAY AFTER     legacy_md5 caches → 0, stats fresh, no NEW red jobs
```

**Three things people get wrong:** skipping `ANALYZE` (→ "it's slow now"); `VACUUM FULL` on a live
system (→ total outage); unpausing everything at once (→ cache-miss stampede).
