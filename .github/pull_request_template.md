### Live Activity QA (must check all)
- [ ] Build passes on iOS 17+
- [ ] Exactly one `Activity.request` in app target
- [ ] No `startActivity(seed:)` outside `LiveActivityManager`
- [ ] 🎬 logs via `addToAppLogsCritical` (push & no-push)
- [ ] Unplug ends via `endActive(...)` (no `endAll("local unplug")`)
- [ ] Foreground gate present in wrapper
- [ ] Debounce, cooldown & thrash guards in place
- [ ] `docs/RELEASE_QA.md` steps re-checked
