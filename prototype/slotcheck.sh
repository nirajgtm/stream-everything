#!/usr/bin/env bash
# Is the connection genuinely in use, or is the server holding a dead session?
#
# Compares two independent sources: the TCP connections this machine actually
# holds, and what the server believes. If nothing local is connected but the
# server still reports a slot in use, that is a ghost - typically left behind by
# a transfer that was interrupted rather than finished.
cd "$(dirname "$0")/.."

SERVER=$(grep '^XTREAM_SERVER=' xtream.properties | cut -d= -f2- | tr -d ' \r')
USERNAME=$(grep '^XTREAM_USER=' xtream.properties | cut -d= -f2- | tr -d ' \r')
PASSWORD=$(grep '^XTREAM_PASS=' xtream.properties | cut -d= -f2- | tr -d ' \r')
HOST=$(printf '%s' "$SERVER" | sed -E 's#^https?://##' | cut -d/ -f1 | cut -d: -f1)

echo "provider : $HOST"
IPS=$(dig +short "$HOST" 2>/dev/null | grep -E '^[0-9]' | tr '\n' '|' | sed 's/|$//')
echo "addresses: ${IPS:-<unresolved>}"

echo
echo "local TCP connections to the provider (or any edge node):"
# Edge nodes differ from the origin, so match the resolved IPs and also show any
# connection held by the tools involved here.
LOCAL=$(lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
  | grep -Ei "${IPS:-__none__}|Python.*:80|curl|VLC" | grep -v '127\.0\.0\.1')
if [ -n "$LOCAL" ]; then
  echo "$LOCAL" | sed 's/^/  /'
  LOCAL_COUNT=$(printf '%s\n' "$LOCAL" | wc -l | tr -d ' ')
else
  echo "  none"
  LOCAL_COUNT=0
fi

ACTIVE=$(curl -s --max-time 10 "$SERVER/player_api.php?username=$USERNAME&password=$PASSWORD" \
  | python3 -c 'import sys,json;u=json.load(sys.stdin)["user_info"];print(u.get("active_cons"),u.get("max_connections"))' 2>/dev/null)
SET=${ACTIVE% *}; CAP=${ACTIVE#* }

echo
echo "server reports : ${SET:-?} / ${CAP:-?} connections in use"
echo "this machine   : $LOCAL_COUNT open to the provider"
echo
if [ "${SET:-0}" = "0" ]; then
  echo "VERDICT: slot is FREE - good to start."
elif [ "$LOCAL_COUNT" -gt 0 ]; then
  echo "VERDICT: genuinely in use by a local process (see above)."
else
  echo "VERDICT: GHOST - the server is holding a session nothing here owns."
  echo "         Left by an interrupted transfer; wait for it to expire."
fi
