# win-hwc — HWC Windows route-integrity test app

Minimal ASP.NET (.NET Framework) app for the `hwc_buildpack`. No build step: the
`.ashx` handlers are compiled at runtime by ASP.NET, so you just `cf push` the files.

## Files
- `web.config` — marks the app as a .NET app for HWC (required)
- `whoami.ashx` — echoes socket peer (`remote_addr`) + forwarding headers
- `callout.ashx` — c2c driver: calls another app's internal address
- `health.ashx` — returns `ok`
- `Default.htm` — index page

## Push
```bash
cf push -f manifest.yml            # from this directory
cf map-route win-hwc apps.internal --hostname win-hwc   # for c2c
```

## Endpoints (note the .ashx suffix)
- `https://win-hwc.<apps-domain>/whoami.ashx`
- `https://win-hwc.<apps-domain>/callout.ashx?target=win-bin.apps.internal:8080&path=/whoami`
- `https://win-hwc.<apps-domain>/health.ashx`
