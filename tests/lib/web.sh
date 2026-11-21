#!/usr/bin/env bash
# Browser-free Nextcloud login: GET /login for csrf, POST creds, verify the
# authenticated session. Reproduces the request shape that once hung in prod.
login_test() {
  local PW="$1" JAR="/tmp/nc-test-cookies.txt" HTML="/tmp/nc-test-page.html"

  rm -f "$JAR" "$HTML"
  local page token code final
  page="$(curl -s -c "$JAR" "$BASE_URL/login")"

  # NC 34 puts the csrf token in body[data-requesttoken]; older versions
  # rendered a name="requesttoken" input — accept both, fail loudly if absent.
  token="$(printf '%s' "$page" | grep -oE 'data-requesttoken="[^"]+"' | head -1 \
    | sed -E 's/.*="([^"]+)".*/\1/' || true)"
  if [ -z "$token" ]; then
    token="$(printf '%s' "$page" | grep -oE 'name="requesttoken"[[:space:]]+value="[^"]+"' | head -1 \
      | sed -E 's/.*value="([^"]+)".*/\1/' || true)"
  fi
  if [ -z "$token" ]; then
    echo "  FAIL: no csrf token found on /login page" >&2
    exit 1
  fi

  code="$(curl -s -L -b "$JAR" -c "$JAR" -o "$HTML" \
    -w '%{http_code}' \
    --header "Origin: $BASE_URL" \
    --data-urlencode "user=admin" \
    --data-urlencode "password=$PW" \
    --data-urlencode "requesttoken=$token" \
    "$BASE_URL/login")"

  # authoritative session proof: OCS self-query with the session cookie
  # (reaching /apps/files is not proof — it renders for anonymous users too)
  local whoami
  whoami="$(curl -s -b "$JAR" -H 'OCS-APIRequest: true' \
    "$BASE_URL/ocs/v2.php/cloud/user?format=json" || true)"
  echo "$whoami" | grep -q '"id":"admin"' || {
    echo "  FAIL session not identified as admin (code=$code, whoami=${whoami:0:120})" >&2
    exit 1
  }
  rm -f "$JAR" "$HTML"
}
