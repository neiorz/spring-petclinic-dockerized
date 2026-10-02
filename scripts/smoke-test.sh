#!/usr/bin/env bash
##############################################################################
# Stage 7 - Automated smoke tests
#
# Fast, read-only-ish checks against the freshly deployed stack:
#   1. Application homepage
#   2. Key MVC pages
#   3. Actuator health (includes DB connectivity)
#   4. Prometheus metrics endpoint
#   5. A real DB write + read round-trip (create owner, find owner)
#   6. Prometheus is scraping the app
#   7. Grafana is up and knows about the Prometheus datasource
#
# Exit code 0 = everything healthy, 1 = the deployment is broken.
##############################################################################
set -u

APP_URL="${APP_URL:-http://localhost:8080}"
PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_CREDS="${GRAFANA_CREDS:-admin:admin}"

PASS=0
FAIL=0
LASTNAME="Smoke$RANDOM"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }

check() {   # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  [%s] %s\n' "$(green OK)" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  [%s] %s\n' "$(red FAIL)" "$desc"
  fi
}

expect_code() {  # expect_code <url> <expected> <desc>
  local url="$1" want="$2" desc="$3" got
  got=$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 000)
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  [%s] %s (HTTP %s)\n' "$(green OK)" "$desc" "$got"
  else
    FAIL=$((FAIL+1)); printf '  [%s] %s - expected HTTP %s, got %s\n' "$(red FAIL)" "$desc" "$want" "$got"
  fi
}

echo "======================================================"
echo " SMOKE TESTS  -  ${APP_URL}"
echo "======================================================"

echo
echo "-- 1. Application availability --"
expect_code "${APP_URL}/"                    200 "Homepage is served"
expect_code "${APP_URL}/owners/find"         200 "Owner search page"
expect_code "${APP_URL}/owners/new"          200 "New owner form"
expect_code "${APP_URL}/vets"                200 "Veterinarians page"

echo
echo "-- 2. Actuator / readiness --"
expect_code "${APP_URL}/actuator/health"     200 "Actuator health is UP"

HEALTH_JSON=$(curl -sS --max-time 10 "${APP_URL}/actuator/health" 2>/dev/null || true)
if printf '%s' "$HEALTH_JSON" | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then
  PASS=$((PASS+1)); printf '  [%s] Health payload reports status UP\n' "$(green OK)"
else
  FAIL=$((FAIL+1)); printf '  [%s] Health payload does not report UP: %s\n' "$(red FAIL)" "$HEALTH_JSON"
fi

echo
echo "-- 3. Monitoring endpoints --"
expect_code "${APP_URL}/actuator/prometheus" 200 "Prometheus metrics endpoint"

METRICS=$(curl -sS --max-time 10 "${APP_URL}/actuator/prometheus" 2>/dev/null || true)
if printf '%s' "$METRICS" | grep -q 'http_server_requests'; then
  PASS=$((PASS+1)); printf '  [%s] HTTP request metrics are being recorded\n' "$(green OK)"
else
  FAIL=$((FAIL+1)); printf '  [%s] http_server_requests metrics missing\n' "$(red FAIL)"
fi

echo
echo "-- 4. Database round-trip (create + find an owner) --"
POST_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST "${APP_URL}/owners/new" \
  --data-urlencode "firstName=Smoke" \
  --data-urlencode "lastName=${LASTNAME}" \
  --data-urlencode "address=1 Test Street" \
  --data-urlencode "city=Testville" \
  --data-urlencode "telephone=0123456789" 2>/dev/null || echo 000)

if [ "$POST_CODE" = "302" ] || [ "$POST_CODE" = "200" ]; then
  PASS=$((PASS+1)); printf '  [%s] POST /owners/new created an owner (HTTP %s)\n' "$(green OK)" "$POST_CODE"
else
  FAIL=$((FAIL+1)); printf '  [%s] POST /owners/new failed (HTTP %s)\n' "$(red FAIL)" "$POST_CODE"
fi

if curl -sS -L --max-time 15 "${APP_URL}/owners?lastName=${LASTNAME}" 2>/dev/null | grep -q "Smoke ${LASTNAME}"; then
  PASS=$((PASS+1)); printf '  [%s] Created owner is readable back from the database\n' "$(green OK)"
else
  FAIL=$((FAIL+1)); printf '  [%s] Created owner could not be found again\n' "$(red FAIL)"
fi

echo
echo "-- 5. Prometheus --"
expect_code "${PROM_URL}/-/ready" 200 "Prometheus is ready"

TARGETS_UP=false
# A freshly (re)started app is marked DOWN until the next scrape succeeds
# (scrape_interval is 10s), so retry for a bounded time instead of failing
# instantly. Stage 7 must not depend on Stage 6 happening to have waited long enough.
for _try in $(seq 1 10); do
  TARGETS=$(curl -sS --max-time 10 "${PROM_URL}/api/v1/targets" 2>/dev/null || true)
  if printf '%s' "$TARGETS" | jq -e '.data.activeTargets[]? | select(.labels.job=="spring-petclinic" and .health=="up")' >/dev/null 2>&1; then
    TARGETS_UP=true; break
  fi
  sleep 3
done

if [ "$TARGETS_UP" = "true" ]; then
  PASS=$((PASS+1)); printf '  [%s] spring-petclinic target is UP in Prometheus\n' "$(green OK)"
else
  FAIL=$((FAIL+1)); printf '  [%s] spring-petclinic target is not UP in Prometheus\n' "$(red FAIL)"
fi

echo
echo "-- 6. Grafana --"
expect_code "${GRAFANA_URL}/api/health" 200 "Grafana API is healthy"

DS=$(curl -sS --max-time 10 -u "${GRAFANA_CREDS}" "${GRAFANA_URL}/api/datasources" 2>/dev/null || true)
if printf '%s' "$DS" | grep -qi 'prometheus'; then
  PASS=$((PASS+1)); printf '  [%s] Prometheus datasource is provisioned in Grafana\n' "$(green OK)"
else
  FAIL=$((FAIL+1)); printf '  [%s] Prometheus datasource missing in Grafana\n' "$(red FAIL)"
fi

echo
echo "======================================================"
echo " RESULT: ${PASS} passed, ${FAIL} failed"
echo "======================================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
