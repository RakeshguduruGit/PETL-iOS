# Release QA — Live Activity (PETL)

## Pass criteria
- Every allowed start prints `🎬 Started …` and `✅ post-request system count=1 tracked=…`.
- No duplicate activities (count never > 1).
- Unplug > debounce ends **by ID** via `endActive(...)`. No `endAll("local unplug")`.
- No "Target is not foreground" on start (deferral is used).
- No ETA dash/0m while charging.
- Background updates appear when expected.
- Startup recovery/reattach behave as designed.

## Quick runbook (Debug or Release)
1) Launch while charging (before app active) → defers, then `🎬` + `✅`.
2) Snapshot/ensure start in foreground → `🎬` + `✅`, count=1.
3) Thrash guard: a second start <2s → `⏭️ Skip start — THRASH-GUARD`.
4) Unplug < debounce → only "Debounce canceled…", **no** "Unplug confirmed…".
5) Unplug > debounce → `endActive(id)` → `✅ end done`.
6) 100% → `🎯 …` then end sequence.
7) Relaunch while charging → `🧷 Reattached …` (no new start).
8) Relaunch unplugged with stray → `🔄 Startup recovery … remaining=0`.
9) Background 1–2 min → `📡 Live Activity update queued remotely (background)`.
