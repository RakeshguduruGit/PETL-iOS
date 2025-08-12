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
