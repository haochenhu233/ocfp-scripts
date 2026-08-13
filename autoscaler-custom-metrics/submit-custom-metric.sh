#!/usr/bin/env bash
# Submit a custom metric to metricsforwarder from INSIDE an app container.
# Usage (inside `cf ssh <app>`):
#   ./submit-custom-metric.sh <metric-name> [value]
# Auto-detects mTLS vs basic-auth from VCAP_SERVICES and prints the HTTP status.
# Deliberately NO set -e: every failure prints a diagnostic instead of dying silently.

METRIC="${1:?usage: $0 <metric-name> [value]}"
VALUE="${2:-42}"
CURL_OPTS=(-sk --max-time 20 -w '\nHTTP %{http_code}\n')

fail() { echo "ERROR: $*" >&2; exit 1; }

echo ">> environment sanity:"
echo "   VCAP_APPLICATION: ${VCAP_APPLICATION:+present ($(echo "$VCAP_APPLICATION" | wc -c) bytes)}${VCAP_APPLICATION:-MISSING}"
echo "   VCAP_SERVICES:    ${VCAP_SERVICES:+present ($(echo "$VCAP_SERVICES" | wc -c) bytes)}${VCAP_SERVICES:-MISSING}"
echo "   CF_INSTANCE_CERT: ${CF_INSTANCE_CERT:-MISSING}$( [ -f "${CF_INSTANCE_CERT:-/nonexistent}" ] && echo ' (file exists)' || echo ' (file NOT found)')"

[ -n "${VCAP_APPLICATION:-}" ] || fail "VCAP_APPLICATION not set - not an app container env? (try: env | grep VCAP)"
[ -n "${VCAP_SERVICES:-}" ]    || fail "VCAP_SERVICES not set - app not bound, or not restarted after binding"

APP_GUID=$(echo "$VCAP_APPLICATION" | grep -o '"application_id":"[^"]*' | cut -d'"' -f4)
[ -n "$APP_GUID" ] || fail "could not extract application_id from VCAP_APPLICATION"
echo "   APP_GUID:         $APP_GUID"

MTLS_URL=$(echo "$VCAP_SERVICES" | grep -o '"mtls_url":"[^"]*' | cut -d'"' -f4 | head -1)
BASIC_URL=$(echo "$VCAP_SERVICES" | grep -o '"url":"https://autoscalermetrics[^"]*' | cut -d'"' -f4 | head -1)
USERNAME=$(echo "$VCAP_SERVICES" | grep -o '"username":"[^"]*' | cut -d'"' -f4 | head -1)
PASSWORD=$(echo "$VCAP_SERVICES" | grep -o '"password":"[^"]*' | cut -d'"' -f4 | head -1)
echo "   mtls_url:         ${MTLS_URL:-<none>}"
echo "   basic url:        ${BASIC_URL:-<none>} (username: ${USERNAME:-<none>})"

BODY=$(printf '{"instance_index":%s,"metrics":[{"name":"%s","value":%s,"unit":""}]}' \
  "${CF_INSTANCE_INDEX:-0}" "$METRIC" "$VALUE")
echo ">> payload: $BODY"

if [ -n "$MTLS_URL" ] && [ -f "${CF_INSTANCE_CERT:-/nonexistent}" ]; then
  echo ">> mTLS submission (instance-identity cert) to $MTLS_URL"
  curl "${CURL_OPTS[@]}" \
    --cert "$CF_INSTANCE_CERT" --key "$CF_INSTANCE_KEY" \
    -X POST "${MTLS_URL}/v1/apps/${APP_GUID}/metrics" \
    -H 'Content-Type: application/json' -d "$BODY"
  rc=$?
elif [ -n "$BASIC_URL" ] && [ -n "$USERNAME" ]; then
  echo ">> basic-auth submission to $BASIC_URL"
  curl "${CURL_OPTS[@]}" -u "${USERNAME}:${PASSWORD}" \
    -X POST "${BASIC_URL}/v1/apps/${APP_GUID}/metrics" \
    -H 'Content-Type: application/json' -d "$BODY"
  rc=$?
else
  echo "ERROR: no usable custom_metrics credentials found in VCAP_SERVICES."
  echo "  mtls_url:  ${MTLS_URL:-<none>}  (CF_INSTANCE_CERT: ${CF_INSTANCE_CERT:-<unset>})"
  echo "  url:       ${BASIC_URL:-<none>}  username: ${USERNAME:-<none>}"
  echo "This itself is diagnostic: an x509-only binding + missing identity cert cannot submit."
  exit 2
fi

[ $rc -eq 0 ] || echo "NOTE: curl exit code $rc (28=timeout, 35/58=TLS handshake, 6=DNS, 7=conn refused)"

cat <<'EOF'

Status meaning: 401/403 = auth (binding_db / cert)   400 = metric not in policy
                2xx = accepted -> check `cf tail <app> --envelope-class metrics`,
                then `cf asm <app> <metric>` after ~2 min.
                HTTP 000 + curl exit code = never reached MF (route/TLS/DNS issue).
EOF
