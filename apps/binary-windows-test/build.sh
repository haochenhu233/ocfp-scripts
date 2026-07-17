#!/usr/bin/env bash
# Cross-compile the Windows exe that binary_buildpack will run.
# Run on any OS with Go installed; no cgo, pure stdlib.
set -euo pipefail
cd "$(dirname "$0")"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o app.exe .
echo "built app.exe ($(du -h app.exe | cut -f1))"
