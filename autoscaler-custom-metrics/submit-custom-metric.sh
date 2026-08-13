#!/usr/bin/env bash
# Submit a custom metric to metricsforwarder from INSIDE an app container.
# Usage (inside `cf ssh <app>`):
#   ./submit-custom-metric.sh <metric-name> [value]
# Auto-detects mTLS vs basic-auth from VCAP_SERVICES and prints the HTTP status.
set -euo pipefail

METRIC="${1:?usage: $0 <metric-name> [value]}"
VALUE="${2:-42}"

APP_GUID=$(echo "$VCAP_APPLICATION" | grep -o '"application_id":"[^"]*' | cut -d'"' -f4)
[ -n "$APP_GUID" ] || { echo "ERROR: could not extract app GUID from VCAP_APPLICATION"; exit 1; }

BODY=$(printf '{"instance_index":%s,"metrics":[{"name":"%s","value":%s,"unit":""}]}' \
  "${CF_INSTANCE_INDEX:-0}" "$METRIC" "$VALUE")

MTLS_URL=$(echo "$VCAP_SERVICES" | grep -o '"mtls_url":"[^"]*' | cut -d'"' -f4 | head -1)
BASIC_URL=$(echo "$VCAP_SERVICES" | grep -o '"url":"https://autoscalermetrics[^"]*' | cut -d'"' -f4 | head -1)
USERNAME=$(echo "$VCAP_SERVICES" | grep -o '"username":"[^"]*' | cut -d'"' -f4 | head -1)
PASSWORD=$(echo "$VCAP_SERVICES" | grep -o '"password":"[^"]*' | cut -d'"' -f4 | head -1)

if [ -n "$MTLS_URL" ] && [ -f "${CF_INSTANCE_CERT:-}" ]; then
  echo ">> mTLS submission (instance-identity cert) to $MTLS_URL"
  curl -sk -w '\nHTTP %{http_code}\n' \
    --cert "$CF_INSTANCE_CERT" --key "$CF_INSTANCE_KEY" \
    -X POST "${MTLS_URL}/v1/apps/${APP_GUID}/metrics" \
    -H 'Content-Type: application/json' -d "$BODY"
elif [ -n "$BASIC_URL" ] && [ -n "$USERNAME" ]; then
  echo ">> basic-auth submission to $BASIC_URL"
  curl -sk -w '\nHTTP %{http_code}\n' -u "${USERNAME}:${PASSWORD}" \
    -X POST "${BASIC_URL}/v1/apps/${APP_GUID}/metrics" \
    -H 'Content-Type: application/json' -d "$BODY"
else
  echo "ERROR: no usable custom_metrics credentials found in VCAP_SERVICES."
  echo "  mtls_url:  ${MTLS_URL:-<none>}  (CF_INSTANCE_CERT: ${CF_INSTANCE_CERT:-<unset>})"
  echo "  url:       ${BASIC_URL:-<none>}  username: ${USERNAME:-<none>}"
  echo "This itself is diagnostic: an x509-only binding + missing identity cert cannot submit."
  exit 2
fi

cat <<'EOF'

Status meaning: 401/403 = auth (binding_db / cert)   400 = metric not in policy
                2xx = accepted -> check `cf tail <app> --envelope-class metrics`,
                then `cf asm <app> <metric>` after ~2 min.
EOF
