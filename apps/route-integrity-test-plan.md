# Windows route-integrity test plan (cf-deployment 52.0.0 -> 56.4.0)

Verifies the impact of the cf-deployment v53.0.0+ change that makes Windows
route-integrity (the `envoy-nginx` per-container mTLS proxy) mandatory.

Run the whole capture **before** the upgrade (baseline), then the **identical**
commands after, and diff. Nothing here modifies the platform except optional scaling.

## Prerequisites (already done)
- `win-hwc` (hwc_buildpack) and `win-bin` (binary_buildpack) pushed, `stack: windows`
- external routes mapped, and internal routes for c2c:
  ```
  cf map-route win-hwc apps.internal --hostname win-hwc
  cf map-route win-bin apps.internal --hostname win-bin
  ```
- c2c network policies on the container port (8080):
  ```
  cf add-network-policy win-hwc --destination win-bin --protocol tcp --port 8080
  cf add-network-policy win-bin --destination win-hwc --protocol tcp --port 8080
  ```

## 0. Discover the real routes (do NOT hardcode the domain)
```bash
HWC=https://$(cf app win-hwc | awk '/^routes:/{print $2}')
BIN=https://$(cf app win-bin | awk '/^routes:/{print $2}')
echo "$HWC"; echo "$BIN"                 # sanity check
OUT=win-baseline-52.txt                  # after upgrade use: win-after-56.txt
```
`-k` is used on every curl so an internal apps-domain CA does not block the test.

## 1-3. Functional capture (from your shell)
```bash
{
echo "===== $(cf target | tr -d '\n') ====="

echo; echo "== T1  route works + latency =="
for u in "$HWC" "$BIN"; do
  curl -ksS -o /dev/null -w "%{url_effective}  code=%{http_code}  time=%{time_total}s\n" "$u/"
done

echo; echo "== T2  source IP the app sees =="
echo "-- win-hwc --"; curl -ksS "$HWC/whoami.ashx"; echo
echo "-- win-bin --"; curl -ksS "$BIN/whoami"; echo

echo; echo "== T3  c2c (by container IP; still enforced by the network policy) =="
# grep (not sed) so a missing field yields empty, never the whole JSON line.
val() { curl -ksS "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
BININT=$(val "$BIN/whoami"      cf_instance_internal_ip); BINCELL=$(val "$BIN/whoami"      cf_instance_ip)
HWCINT=$(val "$HWC/whoami.ashx" cf_instance_internal_ip); HWCCELL=$(val "$HWC/whoami.ashx" cf_instance_ip)
echo "win-bin ip=$BININT cell=$BINCELL   win-hwc ip=$HWCINT cell=$HWCCELL"
if [ "$BINCELL" = "$HWCCELL" ] && [ -n "$BINCELL" ]; then
  echo "same cell -> c2c-by-IP should work"
else
  echo "DIFFERENT cells -> Windows container subnets are per-cell; c2c-by-IP will time out"
  echo "(pre-existing Windows networking, unrelated to route integrity; co-locate both apps on one cell to test empirically)"
fi
echo "-- hwc -> bin --"; curl -ksS --max-time 15 "$HWC/callout.ashx?target=$BININT:8080&path=/whoami"; echo
echo "-- bin -> hwc --"; curl -ksS --max-time 15 "$BIN/callout?target=$HWCINT:8080&path=/whoami.ashx"; echo
} | tee "$OUT"
```

> c2c by **container IP** deliberately bypasses `apps.internal` DNS. A passing T3
> returns the OTHER app's whoami with its `remote_addr` = the CALLER's container IP
> (not `127.0.0.1`, not a router IP) — proof the proxy is not on the c2c path. This
> only works when **both apps are on the same Windows cell**, because container subnets
> (`172.30.x.x`) are assigned per-cell and are not routable cross-cell in this env.
>
> **You may not even need this test.** The route-integrity proxy sits on the
> `*_tls_proxy` ports from `cf_instance_ports` (e.g. 40000 / 61001 / 61443), while the
> app listens on 8080, so c2c to 8080 structurally bypasses the proxy. And the absence
> of a plain `external` port for internal 8080 in `cf_instance_ports` (only
> `external_tls_proxy`) is direct proof that `enable_unproxied_port_mappings:false`
> removed the plaintext host port — i.e. T4 is confirmed without a jumpbox.
>
> `apps.internal` not resolving and cross-cell c2c timing out are the same pre-existing
> Windows-networking matter (also broken on 52.0.0), independent of this upgrade. Only
> worth chasing if the client's real Windows apps use c2c in production.

```bash
# (T1 warm-latency note) run T1 two or three times and record the WARM number;
# win-hwc's first hit is ASP.NET/IIS cold start, not representative.
```

Baseline (52.0.0) should show:
- T1: both `code=200`.
- T2: `remote_addr` is a gorouter/cell IP (a `10.x`); `x_forwarded_for` is your real client IP.
- T3: both `"ok":true,"status":200`; inside the body the destination's `remote_addr`
  is the caller's overlay IP (`10.255.x`).

Check the `"port"` field in T2. If it is not `8080`, change the `:8080` in the T3
`target` values and in the network policies to match.

## 4. Direct cell:port  (optional; needs reachability to the cell network)
Confirms that direct `cell-IP:host-port` access (bypassing the routers) is blocked
after the upgrade. **No cfdot/BBS access needed** — the app reports its own cell IP
and host port via `CF_INSTANCE_ADDR` / `CF_INSTANCE_PORTS`.
```bash
# read the cell-ip:host-port straight from the app
ADDR=$(curl -ksS "$HWC/whoami.ashx" | sed 's/.*"cf_instance_addr":"\([^"]*\)".*/\1/')
echo "cell addr: $ADDR"
curl -ksS "$HWC/whoami.ashx" | sed 's/.*"cf_instance_ports":"\([^"]*\)".*/all ports: \1/'

# from any host that can route to the cell network (your bastion, if it can reach cells):
curl -ksS -o /dev/null -w "direct code=%{http_code}  time=%{time_total}s\n" "http://$ADDR/health.ashx"
```
Baseline (52.0.0): reachable, `code=200`. After upgrade: connection reset / TLS
handshake error (the port now demands a router client cert).

Skip this test entirely if your bastion cannot route to the diego cell subnet — it
only confirms the anti-pattern behavior we are already confident about. If you
prefer cfdot, it lives on the Diego VMs (not the bastion): `bosh ssh scheduler/0`
(or `diego-api/0`) and run it there.

## 5. Capacity baseline
```bash
bosh -d <cf-deployment-name> vms --vitals | grep -iE 'windows|Memory'
cf app win-hwc
```
Record the Windows cells' memory. To make the delta obvious, optionally
`cf scale win-hwc -i 3` now (so it is ~4 x 32 MB after).

## Then: upgrade, and re-run identically
- Leave the apps, routes, and policies in place. The upgrade evacuates them onto the
  new cells automatically; you re-test the same apps.
- Re-run sections 0-5 with `OUT=win-after-56.txt`.
- `diff win-baseline-52.txt win-after-56.txt`.

### Expected changes (and only these)
| Test | 52.0.0 | 56.4.0 | Meaning |
|---|---|---|---|
| T2 `remote_addr` | gorouter/cell IP | `127.0.0.1` | proxy inserted; harmless (XFF unchanged) |
| T2 `x_forwarded_for` | client IP | client IP | unchanged — the correct client-IP source |
| T4 direct cell:port | 200 | refused | anti-pattern only |
| T5 free memory | baseline | down ~32 MB x instances | real ops cost |
| T1 latency | baseline | slightly higher | extra TLS hop |
| T1 codes / T3 c2c | 200 / ok:true | 200 / ok:true | normal apps and c2c unaffected |

If T1 codes or T3 c2c change in any way other than latency, that is a real finding —
capture the output.
