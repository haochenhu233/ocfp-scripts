# apps — Windows route-integrity test apps

Minimal Windows test apps for verifying the cf-deployment v53.0.0+ change that makes
Windows routing-integrity (the `envoy-nginx` per-container mTLS proxy) mandatory.
Push one of each buildpack, capture behavior on the current version, upgrade, re-run.

- [`hwc-windows-test/`](hwc-windows-test/) — `win-hwc`, `hwc_buildpack` (.NET Framework, no build step)
- [`binary-windows-test/`](binary-windows-test/) — `win-bin`, `binary_buildpack` (single-file Go exe)

Both expose the same behavior (`/whoami`, `/callout`, `/health`) and act as each other's
container-to-container peer. Put both in one org/space and add a c2c policy:

```bash
cf add-network-policy win-hwc --destination win-bin --protocol tcp --port 8080
cf add-network-policy win-bin --destination win-hwc --protocol tcp --port 8080
```

What to look for across the upgrade:
- `/whoami` `remote_addr`: `gorouter/cell IP` -> `127.0.0.1`, `x_forwarded_for` unchanged (harmless)
- `/callout` c2c: unchanged before and after (proxy is not on the c2c path)
- direct `cell-IP:host-port`: reachable before, refused after (anti-pattern only)
- Windows cell free memory: down ~32 MB per app instance
