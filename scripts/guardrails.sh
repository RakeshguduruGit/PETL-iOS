#!/usr/bin/env bash
set -euo pipefail

echo "🔒 Running stability guardrails..."

# 1) Only BatteryTrackingManager may call insertPower (except end marker line)
violations=$(git diff --cached -U0 | grep -E "^\+.*insertPower\(" | grep -v "BatteryTrackingManager.swift" || true)
if [[ -n "$violations" ]]; then
  echo "❌ insertPower() may only be called from BatteryTrackingManager"
  echo "$violations"
  exit 1
fi

# 2) No subscriptions to .powerDBDidChange outside parent VM / ContentView
violations=$(git diff --cached -U0 | grep -E "^\+.*powerDBDidChange" | grep -vE "ContentView.swift|ChartsVM" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Subscribing to .powerDBDidChange is only allowed in ChartsVM/ContentView"
  echo "$violations"
  exit 1
fi

# 3) Power chart must be bars; battery must not use BarMark
violations=$(git diff --cached -U0 | grep -E "^\+.*LineMark" | grep "ChargingPowerBarsChart" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Power chart must use bars (no LineMark in ChargingPowerBarsChart)"
  echo "$violations"
  exit 1
fi
violations=$(git diff --cached -U0 | grep -E "^\+.*BarMark" | grep "SimpleBatteryChart" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Battery chart must not use BarMark"
  echo "$violations"
  exit 1
fi

# 4) Stability-locked fences must remain intact
missing=$(git diff --cached | grep -E "BEGIN STABILITY-LOCKED|END STABILITY-LOCKED" || true)
if [[ -z "$missing" ]]; then
  echo "❌ Stability-locked fences missing in your changes"
  exit 1
fi

# 5) Check for direct ChargeDB.shared access outside BatteryTrackingManager
violations=$(git diff --cached -U0 | grep -E "^\+.*ChargeDB\.shared" | grep -v "BatteryTrackingManager.swift" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Direct ChargeDB.shared access only allowed in BatteryTrackingManager"
  echo "$violations"
  exit 1
fi

# 6) Ensure unique index constraint is preserved
violations=$(git diff --cached -U0 | grep -E "^\-.*CREATE UNIQUE INDEX.*session_id.*ts" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Unique index on (session_id, ts) must be preserved"
  echo "$violations"
  exit 1
fi

# 7) Check for INSERT OR IGNORE pattern
violations=$(git diff --cached -U0 | grep -E "^\+.*INSERT INTO charge_log" | grep -v "INSERT OR IGNORE" || true)
if [[ -n "$violations" ]]; then
  echo "❌ All charge_log inserts must use INSERT OR IGNORE"
  echo "$violations"
  exit 1
fi

# 8) Cooldown must be >= 8s
violations=$(git diff --cached -U0 | grep -E "^\+.*minRestartInterval:\ TimeInterval\ =\ [0-7]\b" || true)
if [[ -n "$violations" ]]; then
  echo "❌ LiveActivity minRestartInterval must be >= 8s"
  echo "$violations"
  exit 1
fi

# 9) Hysteresis must be >= 0.9s
violations=$(git diff --cached -U0 | grep -E "^\+.*DispatchQueue\.main\.asyncAfter.*\+ 0\.[0-8]" || true)
if [[ -n "$violations" ]]; then
  echo "❌ Charge-state hysteresis must be >= 0.9s"
  echo "$violations"
  exit 1
fi

echo "✅ Guardrails passed"
