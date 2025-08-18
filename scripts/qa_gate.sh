#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ QA gate failed at line $LINENO" >&2' ERR

fail() { echo -e "❌ $1" >&2; exit 1; }
pass() { echo "✅ $1"; }

# Function definitions
check_activity_request_count() {
  echo "— Activity.request (push + fallback)…"
  local hits
  hits=$(git grep -n -E 'Activity<[^>]*PETL[^>]*Attributes[^>]*>\.request' -- PETL/LiveActivityManager.swift || true)
  hits=$(printf "%s\n" "$hits" | grep -vE '^\s*//|^\s*$' || true)
  local count
  count=$(printf "%s\n" "$hits" | sed '/^\s*$/d' | wc -l | tr -d ' ')
  if [[ "$count" -ne 2 ]]; then
    echo "❌ Expected exactly 2 Activity.request calls in LiveActivityManager.swift (push + fallback), found $count"
    echo "$hits"
    exit 1
  fi
  echo "✅ Exactly 2 Activity.request calls (push + fallback)."
}

check_eta_consumers() {
  echo "— SSOT ETA usage…"

  # Allowed producers / mappers (adjust paths if yours differ)
  local allow=(
    "PETL/ChargeStateStore.swift"
    "PETL/ChargingSnapshot.swift"
    "PETL/BatteryTrackingManager.swift"
    "PETL/ETAPresenter.swift"
    "PETL/ChargeEstimator.swift"
    "PETL/SnapshotToLiveActivity.swift"
    "PETL/PETLLiveActivityAttributes.swift"
    "PETL/PETLLiveActivityExtensionAttributes.swift"
  )

  # Build git-grep excludes
  local excludes=()
  for f in "${allow[@]}"; do excludes+=(":!$f"); done
  excludes+=(
    ':!PETLLiveActivityExtension*'  # whole extension target
    ':!Backups/*'
    ':!**/*Tests*.swift'
    ':!**/*.md'
  )

  # Only scan app target sources
  local hits
  hits=$(git grep -n -E '\b(etaMinutes|timeToFull(Minutes)?|minutesToFull)\b' \
          -- PETL "${excludes[@]}" || true)

  # ignore comments
  hits=$(printf "%s\n" "$hits" | grep -vE '^\s*//|^\s*$' || true)

  if [[ -n "$hits" ]]; then
    echo "❌ SSOT violation: ETA referenced outside allowed producers/mapper:"
    echo "$hits"
    exit 1
  fi
  echo "✅ ETA usage confined to SSOT components."
}

check_live_activity_mapping() {
  echo "— Live Activity mapping…"

  # Only the mapper (and the extension target) may build ContentState
  local hits
  hits=$(git grep -n -E '\b(ContentState\s*\(|ActivityContent\.State\s*\()' \
         -- PETL \
         ':!PETL/SnapshotToLiveActivity.swift' \
         ':!PETL/PETLLiveActivityAttributes.swift' \
         ':!PETL/PETLLiveActivityExtensionAttributes.swift' \
         ':!PETLLiveActivityExtension*' \
         ':!Backups/*' ':!**/*.md' || true)

  # ignore comments
  hits=$(printf "%s\n" "$hits" | grep -vE '^\s*//|^\s*$' || true)

  if [[ -n "$hits" ]]; then
    echo "❌ Live Activity violation: inline ContentState construction outside mapper:"
    echo "$hits"
    exit 1
  fi
  echo "✅ Live Activity content mapping is centralized."
}

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

APP_MANAGER="PETL/LiveActivityManager.swift"
BTM="PETL/BatteryTrackingManager.swift"

[[ -f "$APP_MANAGER" ]] || fail "Missing $APP_MANAGER"

# 1) Activity.request count check (only scan manager file)
check_activity_request_count

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

# 9) SSOT: UI must not read UIDevice battery directly
BAD_BATT=$(git grep -n "UIDevice\\.current\\.battery" -- 'PETL/*.swift' | grep -v "BatteryTrackingManager.swift" || true)
[[ -z "$BAD_BATT" ]] || fail "Direct UIDevice battery reads outside BatteryTrackingManager:\n$BAD_BATT"

# 10) Run the refined checks
check_eta_consumers
check_live_activity_mapping

echo "✅ QA gate passed."
