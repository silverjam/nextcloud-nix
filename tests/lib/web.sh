#!/usr/bin/env bash
# Browser-free Nextcloud login: GET /login for csrf, POST creds, verify the
# authenticated session. Reproduces the request shape that once hung in prod.
login_test() {
  local PW="$1" JAR="/tmp/nc-test-cookies.txt" HTML="/tmp/nc-test-page.html"

  rm -f "$JAR"
  local page token code final
  page="$(curl -s -c "$JAR" "$BASE_URL/login")"

  token="$(printf '%s' "$page" \
    | grep -oE 'name="requesttoken"\s+value="[^"]+"' \
    | head -1 | sed -E 's/.*value="([^"]+)".*"$/\1/')"
  [ -n "$token" ] || { echo "  FAIL no requesttoken on /login page" >&2; exit 1; }

  code="$(curl -s -L -b "$JAR" -c "$JAR" -o "$HTML" \
    -w '%{http_code}' --data-urlencode "user=admin" \
    --data-urlencode "password=$PW" \
    --data-urlencode "requesttoken=$token" \
    "$BASE_URL/login")"
  final="$(curl -s -b "$JAR" -L -o /dev/null -w '%{url_effective}' "$BASE_URL/apps/files")"
  case "$final" in */login*) echo "  FAIL redirected back to login: $final" >&2; exit 1;; esac
  grep -q 'data-user="admin"' "$HTML" || {
    echo "  FAIL session page does not show user admin (code=$code)" >&2; exit 1;
  }
  rm -f "$JAR" "$HTML"
}
