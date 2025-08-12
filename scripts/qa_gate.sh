#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ QA gate failed at line $LINENO" >&2' ERR

fail() { echo -e "❌ $1" >&2; exit 1; }
pass() { echo "✅ $1"; }

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

APP_MANAGER="PETL/LiveActivityManager.swift"
BTM="PETL/BatteryTrackingManager.swift"

[[ -f "$APP_MANAGER" ]] || fail "Missing $APP_MANAGER"

# 1) Exactly TWO Activity.request calls (push + fallback), only in LiveActivityManager.swift
REQ_LINES=$(grep -nE 'Activity<[^>]*PETL[^>]*Attributes[^>]*>\.request' "$APP_MANAGER" || true)
REQ_COUNT=$(echo "$REQ_LINES" | sed '/^\s*$/d' | wc -l | xargs)
[[ "$REQ_COUNT" == "2" ]] || fail "Expected exactly 2 Activity.request calls (push + fallback) in $APP_MANAGER, found $REQ_COUNT:\n$REQ_LINES"

# 1a) One must include pushType:.token, one must NOT (no-push)
echo "$REQ_LINES" | grep -q 'pushType:\s*\.token' \
  || fail "No push-path (pushType:.token) Activity.request found."
NO_PUSH_COUNT=$(echo "$REQ_LINES" | grep -vc 'pushType:\s*\.token' | xargs)
[[ "$NO_PUSH_COUNT" -ge 1 ]] || fail "No no-push Activity.request found."

pass "Activity.request count/kinds OK."

# 2) No direct seeded starts outside LiveActivityManager
BAD_SEEDED=$(git grep -n "startActivity(seed:" -- :^PETLLiveActivityExtension* -- ':(exclude)*.md' -- ':(exclude)Backups/*' | grep -v "$APP_MANAGER" || true)
[[ -z "$BAD_SEEDED" ]] || fail "Direct seeded start calls outside LiveActivityManager:\n$BAD_SEEDED"

# 3) Unplug must not end via endAll(\"local unplug\")
BAD_UNPLUG=$(git grep -n 'endAll\\([^)]*local unplug' || true)
[[ -z "$BAD_UNPLUG" ]] || fail "Forbidden endAll(\"local unplug\") found:\n$BAD_UNPLUG"

# 4) Exactly two 🎬 emitters and they use addToAppLogsCritical
STARTERS=$(git grep -n 'Started Live Activity id=' "$APP_MANAGER" || true)
[[ "$(echo "$STARTERS" | sed '/^\s*$/d' | wc -l | xargs)" == "2" ]] \
  || fail "Expected 2 🎬 emitters (push + no-push), found:\n$STARTERS"
echo "$STARTERS" | grep -q 'addToAppLogsCritical' \
  || fail "🎬 logs must use addToAppLogsCritical (not Logger.*)."

# 5) Wrapper visible; seeded private
grep -qE 'func\s+startActivity\(\s*reason:' "$APP_MANAGER" \
  || fail "Wrapper startActivity(reason:) missing."
grep -qE 'private\s+func\s+startActivity\(\s*seed\s+seededMinutes:' "$APP_MANAGER" \
  || fail "Seeded start must be private."

# 6) Foreground gate in wrapper (deferral path)
grep -q 'AppForegroundGate.shared' "$APP_MANAGER" \
  || fail "Foreground gate missing in start wrapper."

# 7) Debounce ends via endActive (and sleep is cancelable)
grep -q 'handleUnplugDetected' "$BTM" || fail "handleUnplugDetected not found."
grep -q 'endActive.*UNPLUG' "$BTM" || fail "Debounce must call endActive(\"UNPLUG…\")."
grep -q 'Task\.sleep' "$BTM" || fail "Debounce sleep must be cancelable (use 'try await Task.sleep')."

# 8) Optional: thrash guard present (warn only)
if ! grep -q 'THRASH-GUARD' "$APP_MANAGER" ; then
  echo "⚠️  THRASH-GUARD not found — consider adding 2–4s guard."
fi

echo "✅ QA gate passed."
