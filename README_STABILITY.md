# STABILITY INVARIANTS

This document defines the core stability rules that MUST be preserved to prevent regressions in power tracking and UI performance.

## Power Persistence Rules

### Warmup Write Pattern
- **At most 1 row (10W) per session** during warmup phase
- **Then measured writes every ≥5s** with throttling
- **True early return** prevents generic path after warmup write
- **Quantized timestamps** to 1-second precision

### Session Lifecycle
- **New UUID on begin** - each charging session gets unique identifier
- **Optional 0W end marker** - clean session closure for charts
- **Smoothing reset on begin/end** - prevents stale data carryover

## Database Constraints

### Unique Index Protection
- **Unique index on (session_id, ts)** prevents duplicate rows
- **INSERT OR IGNORE** - bulletproof against race conditions
- **Coalesced notifications ≥1s** - prevents notification spam

### Thread Safety
- **Single writer path** through BatteryTrackingManager only
- **Coalesced notifications** with minimum interval enforcement

## Live Activity Management

### Transition-Only Triggers
- **Start/end only on transitions** (never from tick())
- **Hard guard prevents double-start** - existing activity check
- **Clean session lifecycle** integration

## UI Architecture

### Single Subscriber Pattern
- **One subscriber to .powerDBDidChange** (parent VM only)
- **Power chart fed by 12h data** - consistent data scope
- **No child view subscriptions** - prevents reload storms

### Chart Specifications
- **Battery chart**: line + area marks
- **Power chart**: bar marks only
- **Each in separate card** with centered titles
- **No chart type mixing** - maintain visual consistency

## Code Organization

### Restricted Entry Points
- **insertPower() calls only in BatteryTrackingManager**
- **No direct DB access from UI or charts**
- **Stability-locked fences** around critical code blocks

### Notification Flow
- **Single source of truth** for power data changes
- **Debounced reloads** with change detection
- **No redundant subscriptions**

## Testing Requirements

### Unit Test Coverage
- **Warmup-once validation** - ensure single write per session
- **Throttle enforcement** - verify 5-second minimum gaps
- **Notification coalescing** - prevent spam
- **Session lifecycle** - proper begin/end handling

### Integration Tests
- **End-to-end charging cycle** validation
- **UI update frequency** verification
- **Memory leak prevention** checks

## Maintenance

### When Changing Behavior
- **Update this document** when intentionally modifying rules
- **Add corresponding tests** for new patterns
- **Verify guardrails** still catch violations
- **Update stability fences** if code structure changes

### Code Review Checklist
- [ ] No insertPower() calls outside BatteryTrackingManager
- [ ] No .powerDBDidChange subscriptions outside ChartsVM/ContentView
- [ ] Power chart uses BarMark only
- [ ] Battery chart uses LineMark + AreaMark only
- [ ] Stability-locked fences remain intact
- [ ] Unit tests pass
- [ ] Guardrails script passes

---

**Last Updated**: December 2024
**Version**: 1.0
