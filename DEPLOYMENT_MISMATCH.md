# ⚠️ DEPLOYMENT MISMATCH DETECTED

## Problem
Vercel is running the **OLD code** without APNs background headers. The latest fixes are **NOT deployed**.

## What's Deployed (WRONG):
```javascript
const payload = {
  app_id: appId,
  filters: [{ field: 'tag', key: 'charging', relation: '=', value: 'true' }],
  content_available: true,
  priority: 10,           // ❌ WRONG - Should be 5
  ttl: 180,               // ❌ WRONG - Should be 300
  data: { type: 'petl-bg-update', timestamp: new Date().toISOString() },
  // ❌ MISSING: apns_push_type_override
  // ❌ MISSING: ios_interruption_level
  // ❌ MISSING: mutable_content
};
```

## What Should Be Deployed (CORRECT):
```javascript
const payload = {
  app_id: appId,
  filters: [{ field: 'tag', key: 'charging', relation: '=', value: 'true' }],
  content_available: true,
  apns_push_type_override: 'background',    // ✅ REQUIRED
  ios_interruption_level: 'passive',        // ✅ REQUIRED
  mutable_content: false,                    // ✅ REQUIRED
  priority: 5,                               // ✅ Background priority
  ttl: 300,                                  // ✅ Increased TTL
  data: { type: 'petl-bg-update', timestamp: new Date().toISOString() },
};
```

## Solution
1. **Redeploy from GitHub** - Vercel should auto-deploy from the latest commit
2. **Or manually update** the file in Vercel dashboard
3. **Or trigger a redeploy** from Vercel dashboard

The correct code is in GitHub at:
- `app/api/cron/send-silent-push/route.ts` ✅
- `api/cron/send-silent-push.js` ✅

