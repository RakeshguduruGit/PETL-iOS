# Silent Push Fix - Background APNs Headers

## Problem Identified

Your Vercel cron endpoint was sending silent pushes, but iOS was **not waking your app** because the OneSignal request was missing critical APNs background push headers.

### What Was Wrong:

**Before (❌ Not working):**
```json
{
  "content_available": true,
  "priority": 10,  // ❌ High priority (wrong for background)
  "data": { "type": "petl-bg-update" }
  // ❌ Missing: apns_push_type_override
  // ❌ Missing: ios_interruption_level
}
```

### What iOS Needs for Background Wakes:

Looking at your iOS code (`OneSignalClient.swift` lines 126-128), the working format is:
```json
{
  "content_available": true,
  "apns_push_type_override": "background",  // ✅ Tells APNs this is background
  "ios_interruption_level": "passive",      // ✅ Passive = won't interrupt user
  "mutable_content": false,                  // ✅ No notification content
  "priority": 5,                             // ✅ Background priority (not 10!)
  "data": { "type": "petl-bg-update" }
}
```

## Fixes Applied

### 1. Updated `api/cron/send-silent-push.js` (Traditional Vercel Format)
- ✅ Added `apns_push_type_override: 'background'`
- ✅ Added `ios_interruption_level: 'passive'`
- ✅ Added `mutable_content: false`
- ✅ Changed `priority: 10` → `priority: 5` (background priority)
- ✅ Increased TTL: `180` → `300` seconds

### 2. Created `app/api/cron/send-silent-push/route.ts` (Next.js App Router)
- ✅ Same fixes applied for Next.js format
- ✅ Matches your existing Vercel project structure

### 3. Updated `vercel.json`
- ✅ Changed cron frequency: `*/3 * * * *` → `*/10 * * * *` (every 10 minutes, not 3)
- Reason: Apple throttles frequent silent pushes heavily. 10-15 minutes is more reliable.

## OneSignal Request Body (After Fix)

**Complete payload sent to OneSignal:**
```json
{
  "app_id": "YOUR_ONESIGNAL_APP_ID",
  "filters": [
    { "field": "tag", "key": "charging", "relation": "=", "value": "true" }
  ],
  "content_available": true,
  "apns_push_type_override": "background",
  "ios_interruption_level": "passive",
  "mutable_content": false,
  "priority": 5,
  "data": {
    "type": "petl-bg-update",
    "timestamp": "2024-01-04T15:42:33.000Z"
  },
  "ttl": 300
}
```

## Why This Fixes the Issue

1. **`apns_push_type_override: "background"`** - Explicitly tells APNs this is a background push (not a user-facing notification)
2. **`ios_interruption_level: "passive"`** - Marks it as non-interrupting (iOS 15+)
3. **`priority: 5`** - Background priority (priority 10 = user-facing, gets throttled)
4. **Frequency reduction** - 10 minutes vs 3 minutes reduces throttling

## Testing

After deploying, you should see:
- ✅ App wakes in background when silent push arrives
- ✅ `handleSilentTick()` runs
- ✅ Live Activity updates via `updateActivityFromBackground()`
- ✅ Chart history updates

## Additional Recommendations

1. **Verify App Capabilities:**
   - ✅ Background Modes → Remote notifications enabled in Xcode
   - ✅ Background App Refresh enabled on device
   - ✅ Low Power Mode OFF (it blocks background work)

2. **Monitor Vercel Logs:**
   - Check `/api/cron/send-silent-push` logs for successful sends
   - Verify `recipients` count > 0

3. **Monitor iOS Logs:**
   - Look for "📨 Silent push received" messages
   - Verify "🔔 Silent push received - triggering background analytics update"

## Files Changed

- `api/cron/send-silent-push.js` - Fixed traditional format
- `app/api/cron/send-silent-push/route.ts` - Created Next.js format (NEW)
- `vercel.json` - Updated cron schedule to 10 minutes

