#!/bin/bash
# Stands in for cswap during UI checks and screenshots, so nothing touches the real Keychain or
# the live login. Point SWAP_ISLAND_CSWAP at this file. State lives in a temp file so a switch sticks.
STATE="${TMPDIR:-/tmp}/fake-cswap-active"
[ -f "$STATE" ] || echo 2 > "$STATE"
ACTIVE=$(cat "$STATE")

row() { # number email five seven expected
  local active=false
  [ "$1" = "$ACTIVE" ] && active=true
  cat <<JSON
{"number":$1,"email":"$2","active":$active,"usageStatus":"ok",
 "usage":{"fiveHour":{"pct":$3,"countdown":"3h 12m"},"sevenDay":{"pct":$4,"countdown":"4d 2h","expectedPct":$5}}}
JSON
}

case "$1" in
  list)
    if [ -n "${FAKE_CSWAP_EMPTY:-}" ]; then
      echo '{"schemaVersion":1,"activeAccountNumber":null,"accounts":[]}'
      exit 0
    fi
    cat <<JSON
{"schemaVersion":1,"activeAccountNumber":$ACTIVE,"accounts":[
$(row 2 "personal@example.com" 14 62 41.2),
$(row 3 "studio@example.com" 0 96 68),
$(row 6 "agency@example.com" 72 48 94.8),
{"number":7,"email":"old@example.com","active":false,"usageStatus":"token_expired","usage":null,
 "lastGoodUsage":{"fiveHour":{"pct":40},"sevenDay":{"pct":55}}}
]}
JSON
    ;;
  switch)
    sleep 0.6
    if [ "$2" = "--strategy" ]; then echo 6 > "$STATE"; else echo "$2" > "$STATE"; fi
    echo '{"schemaVersion":1,"switched":true,"from":1,"to":2,"reason":null}'
    ;;
  add|disable|enable|remove) cat > /dev/null; sleep 0.3 ;;
  --version)
    if [ -f "$STATE-upgraded" ]; then echo "cswap 99.0.0"; else echo "cswap 0.1.0"; fi
    ;;
  upgrade)
    sleep 2
    [ -n "${FAKE_CSWAP_PINNED:-}" ] || touch "$STATE-upgraded"
    ;;
  *) echo '{"schemaVersion":1,"error":{"message":"unsupported"}}'; exit 1 ;;
esac
