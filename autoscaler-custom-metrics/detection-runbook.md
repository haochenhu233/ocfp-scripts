# Autoscaler custom-metrics outage — detection runbook (client SBX)

Context: after upgrading the autoscaler to release 15.13.0 (kit 5.1.0), apps no longer
scale on the RabbitMQ queue-depth custom metric; `cf asm` shows stale data or
"no aggregated metrics found". This runbook isolates the failing hop. Run stages in
order — each stage's result decides the next.

**The pipeline under test:**

```
WRITE (custom metrics only):
  emitter → gorouter → metricsforwarder VM :6201
    [auth: binding creds vs binding_db; validate: metric name vs policy_db]
    → loggr-syslog-agent (same VM, gRPC)
    → loggr-syslog-binding-cache :9000 (drain list)
    → syslog-TLS → CF log-cache VM :6067

READ (all metrics):
  eventgenerator → log-cache :8080 → aggregates → appmetrics_db
  cf asm → gorouter → apiserver → (mTLS) eventgenerator
```

Standard metrics (cpu/memory/throughput) bypass the WRITE path entirely
(CF's cell agents deliver them to log-cache directly).

**Findings already established (2026-08-12):**
- binding-cache is UP in both lab and sbx (`ss` shows agent connected on :9000);
  the `connection refused` log lines are a startup ordering race — red herring.
- Lab runs loggregator-agent 7.7.3, sbx 8.3.19 (from CF exodus, not kit-pinned).
- Release 15.13.x broker defaults `default_credential_type: x509` → new bindings
  get **mtls_url only** (no basic-auth creds). Prime suspect for the outage.
- apiserver logged `sql: no rows` for service_instance `cf3ee224-…` → possible
  DB-content gap (check Stage 5).

---

## Stage 1 — read path health (CPU test)

Standard metric; no app cooperation needed. Proves EG↔log-cache, EG↔apiserver,
DB writes.

```bash
cf bind-service <test-app> <autoscaler-instance> -c cpu-policy.json   # file in this dir
# or if already bound:  cf aasp <test-app> cpu-policy.json
cf autoscaling-policy <test-app>       # confirm policy attached
sleep 120
cf asm <test-app> cpu
```

| Result | Meaning | Next |
|---|---|---|
| cpu rows appear | READ path healthy; outage is WRITE-path only | Stage 2 |
| still "no aggregated metrics found" | READ path also broken (second, independent break) | Stage 6 + check eventgenerator logs for `lookup logcache` / x509 (kit 5.1.0 noble bug → upgrade kit ≥ 5.1.1) |

## Stage 2 — binding credential type

```bash
cf env <test-app> | sed -n '/autoscaler/,/}/p' | grep -E 'mtls_url|"url"|username'
```

| Result | Meaning |
|---|---|
| `mtls_url` only | x509 binding (15.13.x default). Emitter MUST use instance-identity certs. Basic-auth emitters cannot submit at all → likely the outage for this app. |
| `url` + `username`/`password` | binding-secret binding (pre-upgrade or explicit). Basic-auth submission should work → Stage 3B. |

## Stage 3 — manual metric submission (front-door test)

### 3A — mTLS binding (mtls_url only)

Must run INSIDE the app container (instance-identity certs only exist there):

```bash
cf ssh <test-app>
# then inside (or use submit-custom-metric.sh from this dir):
APP_GUID=$(echo $VCAP_APPLICATION | grep -o '"application_id":"[^"]*' | cut -d'"' -f4)
MTLS_URL=$(echo $VCAP_SERVICES | grep -o '"mtls_url":"[^"]*' | cut -d'"' -f4)
curl -sk -w '\nHTTP %{http_code}\n' \
  --cert $CF_INSTANCE_CERT --key $CF_INSTANCE_KEY \
  -X POST "${MTLS_URL}/v1/apps/${APP_GUID}/metrics" \
  -H 'Content-Type: application/json' \
  -d '{"instance_index":0,"metrics":[{"name":"dummy_queue_messages_ready","value":42,"unit":""}]}'
```

### 3B — binding-secret binding (url + username/password)

Runs from anywhere:

```bash
curl -sk -w '\nHTTP %{http_code}\n' -u '<username>:<password>' \
  -X POST "<url>/v1/apps/$(cf app <test-app> --guid)/metrics" \
  -H 'Content-Type: application/json' \
  -d '{"instance_index":0,"metrics":[{"name":"dummy_queue_messages_ready","value":42,"unit":""}]}'
```

### Reading the status code

| Code | Failing check | Meaning |
|---|---|---|
| 401 / 403 | authentication | MF doesn't recognize the creds/cert → binding_db missing rows (DB gap) or cert/CA issue on mTLS route |
| 400 | policy validation | creds OK but metric name not in the app's policy → policy_db missing/wrong policy |
| 2xx | front door passed | metric accepted → Stage 4 to watch delivery |
| timeout / conn refused | route | gorouter → MF route problem (`cf curl` the domain, check route_registrar on MF VM) |

## Stage 4 — delivery to log-cache (only after a 2xx)

Terminal A — keep submitting (repeat Stage 3 in a loop).
Terminal B — on the MF VM:

```bash
bosh -d <autoscaler-dep> ssh metricsforwarder
sudo ss -tnp | grep 6067          # drain to log-cache MUST appear while traffic flows
sudo tail -f /var/vcap/sys/log/loggr-syslog-agent/*.log
#   watch for: "failed to connect to aggregate drain <url>: <err>"  ← exodus log_cache certs / DNS
```

Terminal C — arrival + aggregation:

```bash
cf tail <test-app> --envelope-class metrics   # raw envelope in log-cache (needs log-cache CLI plugin)
sleep 120 && cf asm <test-app> dummy_queue_messages_ready
```

| Observation | Meaning |
|---|---|
| :6067 conn + envelope in `cf tail` + asm rows | ENTIRE pipeline healthy → incident = emitter can't authenticate (x509 default). Apply a remedy below. |
| :6067 never appears / "failed to connect to aggregate drain" | drain hop broken → exodus-sourced log_cache certs stale vs CF (`overlay/base.yml:40-42`) or DNS to `log-cache.service.cf.internal:6067` |
| envelope in `cf tail` but asm empty | WRITE ok, READ broken → Stage 1 should have caught; check apiserver↔EG mTLS + EG logs |

## Stage 5 — DB continuity (the `sql: no rows` thread)

```bash
cf service <autoscaler-instance> --guid        # == cf3ee224-… from apiserver log?
bosh -d <autoscaler-dep> instances             # postgres VM present? (internal-db) or not (ocfp external)
# in the manifest: do *_db point at the ocfp external hostname or autoscalerpostgres.service.cf.internal?
```

If the 5.1.0 upgrade switched internal↔external DB (e.g. as workaround for the OCFP
external-db manifest bug), the new DB started EMPTY → all pre-upgrade instances/
bindings/policies orphaned → recreate them (unbind/rebind every app with its policy)
or point back at the original DB.

## Stage 6 — reference: VM-side log locations

```bash
bosh -d <autoscaler-dep> ssh <instance>
/var/vcap/sys/log/metricsforwarder/            # auth/validation rejects (may need log_level: debug)
/var/vcap/sys/log/loggr-syslog-agent/          # drain connect errors
/var/vcap/sys/log/loggr-syslog-binding-cache/  # CC-sync x509 noise (harmless), :9000 serving
/var/vcap/sys/log/eventgenerator/              # log-cache polling errors (READ path)
/var/vcap/sys/log/golangapiserver/             # asm queries, broker ops, sql errors
sudo /var/vcap/bosh/bin/monit summary
```

---

## Remedies (pick by emitter architecture)

1. **Per-binding basic auth** (required if the emitter runs OUTSIDE the app
   container): `cf unbind-service` then
   `cf bind-service <app> <instance> -c '{"credential-type":"binding-secret", ...policy...}'`
2. **Deployment-wide default**: set
   `autoscaler.apiserver.broker.default_credential_type: binding-secret`
   via kit/env params (restores pre-15.13 behavior for all new bindings).
3. **Modernize emitter to mTLS**: use `mtls_url` with `$CF_INSTANCE_CERT`/`$CF_INSTANCE_KEY`
   (in-container only; certs rotate ~daily — re-read the files on every request).

Known kit issues in this area (fixed on cf-app-autoscaler-genesis-kit develop):
- 5.1.0 OCFP external-db manifest-gen failure (fixed 5.1.1)
- noble: eventgenerator can't resolve `logcache` single-label alias (fixed 5.1.1)
- binding-cache placeholder `api.tls.cn` → harmless-but-noisy CC-sync x509 error
  (cn fix authored; cosmetic)
