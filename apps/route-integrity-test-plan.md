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

echo; echo "== T3  c2c (each app calls the other over apps.internal) =="
echo "-- hwc -> bin --"; curl -ksS "$HWC/callout.ashx?target=win-bin.apps.internal:8080&path=/whoami"; echo
echo "-- bin -> hwc --"; curl -ksS "$BIN/callout?target=win-hwc.apps.internal:8080&path=/whoami.ashx"; echo
} | tee "$OUT"
```

Baseline (52.0.0) should show:
- T1: both `code=200`.
- T2: `remote_addr` is a gorouter/cell IP (a `10.x`); `x_forwarded_for` is your real client IP.
- T3: both `"ok":true,"status":200`; inside the body the destination's `remote_addr`
  is the caller's overlay IP (`10.255.x`).

Check the `"port"` field in T2. If it is not `8080`, change the `:8080` in the T3
`target` values and in the network policies to match.

## 4. Direct cell:port  (optional; needs cell-network / BBS access)
Confirms that direct `cell-IP:host-port` access (bypassing the routers) is blocked
after the upgrade. Skip if reaching a jumpbox on the diego subnet is impractical.
```bash
APPGUID=$(cf app win-hwc --guid)
# on a VM with cfdot/BBS access, e.g.  bosh ssh scheduler/0
cfdot actual-lrps | jq -c --arg g "$APPGUID" \
  'select(.process_guid|startswith($g)) | .actual_lrp_net_info | {address, ports}'
# then from a jumpbox that can reach that cell IP:
curl -ksS -o /dev/null -w "direct code=%{http_code}\n" http://<cell-ip>:<host_port>/health.ashx
```
Baseline: reachable, `code=200`.

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
