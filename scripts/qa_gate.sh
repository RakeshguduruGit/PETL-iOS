#!/usr/bin/env bash
set -euo pipefail

fail() { echo "❌ $1" >&2; exit 1; }
pass() { echo "✅ $1"; }

# 1) Exactly two Activity.request in LiveActivityManager (push + no-push fallback)
REQ_COUNT=$(git grep -n "Activity<.*PETLLiveActivityExtensionAttributes.*>.request" PETL/LiveActivityManager.swift | wc -l | xargs)
[[ "$REQ_COUNT" == "2" ]] || fail "Expected exactly 2 Activity.request in LiveActivityManager (push + no-push), found $REQ_COUNT."

# 2) No direct seeded starts outside LiveActivityManager
BAD_SEEDED=$(git grep -n "startActivity(seed:" -- :^PETLLiveActivityExtension* -- ':(exclude)*.md' | grep -v "LiveActivityManager.swift" || true)
[[ -z "$BAD_SEEDED" ]] || fail "Direct seeded start calls outside LiveActivityManager:\n$BAD_SEEDED"

# 3) Unplug must not call endAll(\"local unplug\")
BAD_UNPLUG=$(git grep -n 'endAll\\([^)]*local unplug' || true)
[[ -z "$BAD_UNPLUG" ]] || fail "Forbidden endAll(\"local unplug\") found:\n$BAD_UNPLUG"

# 4) Must emit 🎬 via addToAppLogsCritical (push & no-push), exactly two emitters
STARTERS=$(git grep -n 'Started Live Activity id=' PETL/LiveActivityManager.swift || true)
echo "$STARTERS" | grep -q 'addToAppLogsCritical' || fail "🎬 logs must use addToAppLogsCritical."
COUNT=$(echo "$STARTERS" | wc -l | xargs)
[[ "$COUNT" == "2" ]] || fail "Expected 2 🎬 emitters (push + no-push), found $COUNT:\n$STARTERS"

# 5) Wrapper visible; seeded private
grep -q "func startActivity(reason:" PETL/LiveActivityManager.swift \
  || fail "Wrapper startActivity(reason:) missing."
grep -q "private.*startActivity.*seed" PETL/LiveActivityManager.swift \
  || fail "Seeded start must be private."

# 6) Foreground gate in wrapper
grep -q "AppForegroundGate\\.shared" PETL/LiveActivityManager.swift \
  || fail "Foreground gate missing in start wrapper."

# 7) Debounce ends via endActive(...)
grep -q "handleUnplugDetected" PETL/BatteryTrackingManager.swift && \
  grep -q "endActive.*UNPLUG" PETL/BatteryTrackingManager.swift \
  || fail "Debounce must call endActive(\"UNPLUG…\")."

# 8) Optional: thrash guard present (warn only)
if ! grep -q "THRASH-GUARD" PETL/LiveActivityManager.swift ; then
  echo "⚠️  THRASH-GUARD not found — consider adding 2–4s guard."
fi

pass "QA gate passed."
