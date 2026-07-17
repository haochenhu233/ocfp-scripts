# win-bin — binary Windows route-integrity test app

Single-file Go server (pure stdlib) for the `binary_buildpack`. You push the
compiled `app.exe`; the `.cfignore` keeps the Go source out of the droplet.

## Build then push
```bash
./build.sh                          # produces app.exe (GOOS=windows GOARCH=amd64)
cf push -f manifest.yml             # from this directory
cf map-route win-bin apps.internal --hostname win-bin   # for c2c
```

## Endpoints
- `https://win-bin.<apps-domain>/whoami`
- `https://win-bin.<apps-domain>/callout?target=win-hwc.apps.internal:8080&path=/whoami.ashx`
- `https://win-bin.<apps-domain>/health`

Note: when calling the HWC app back, use `path=/whoami.ashx` (its endpoints carry
the `.ashx` suffix); the Go app's own endpoints have no suffix.
