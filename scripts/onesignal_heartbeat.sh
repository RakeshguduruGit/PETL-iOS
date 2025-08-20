#!/usr/bin/env bash
# Usage: ONESIGNAL_APP_ID=... ONESIGNAL_API_KEY=... PLAYER_ID=... SOC=65 WATTS=10 ./scripts/onesignal_heartbeat.sh

set -euo pipefail
APP_ID="${ONESIGNAL_APP_ID:?}"
API_KEY="${ONESIGNAL_API_KEY:?}"
PLAYER="${PLAYER_ID:?}"
SOC="${SOC:-65}"
WATTS="${WATTS:-10}"

curl -sS https://api.onesignal.com/notifications \
  -H "Authorization: Basic ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d @- <<JSON
{
  "app_id": "${APP_ID}",
  "include_player_ids": ["${PLAYER}"],
  "content_available": true,
  "mutable_content": false,
  "ttl": 60,
  "ios_interruption_level": "passive",
  "data": { "soc": ${SOC}, "watts": ${WATTS}, "heartbeat": true }
}
JSON
echo
