# Contributing

## Live Activity Guardrails (non-negotiable)
- All starts must call `LiveActivityManager.startActivity(reason:)` (wrapper).
- Seeded start is **private**; never call it directly.
- Exactly two `Activity.request` calls in LiveActivityManager.swift (push + fallback).
  - One with `pushType:.token` (push path)
  - One without pushType (no-push fallback)
- Debounced unplug ends **by ID** via `endActive(...)`. Never call `endAll("local unplug")`.
- Foreground gate must be used. If not active → defer start.
- `🎬 Started …` logs use `addToAppLogsCritical` (push + no-push).
- Debounce must use cancelable `Task.sleep` for proper cancellation.
- See `docs/RELEASE_QA.md` before merging.

CI will block merges if these are violated (see `scripts/qa_gate.sh`).

## Single Source of Truth (SSOT) Rules
- **Battery data**: Only `BatteryTrackingManager` may read `UIDevice.current.battery*`. All other code consumes `ChargeStateStore.shared.snapshot`.
- **ETA usage**: Only `ChargingAnalyticsStore`, `ETAPresenter`, `ChargeEstimator`, and the `BatteryTrackingManager` composer may reference ETA sources. All other code consumes `ChargeStateStore.shared.snapshot.etaMinutes`.
- **Live Activity content**: Only `SnapshotToLiveActivity.makeContent(from:)` may build `ContentState`. No inline `ContentState(...)` construction.
