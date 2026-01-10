# Files to Copy to petl-live-la Repository

## Summary
Vercel is connected to `petl-live-la` repository, but our API routes are in `PETL-iOS`. 
We need to copy these files to `petl-live-la` for Vercel to deploy them.

## Files to Copy

### 1. Next.js App Router Routes (Primary - for Next.js project)
- `app/api/cron/send-silent-push/route.ts` ✅ **CRITICAL - Has APNs fixes**
- `app/api/la/start/route.ts`
- `app/api/la/update/route.ts`
- `app/api/la/end/route.ts`
- `app/api/la/health/route.ts`

### 2. Traditional Vercel Serverless Functions (Backup)
- `api/cron/send-silent-push.js` ✅ **CRITICAL - Has APNs fixes**
- `api/la/start.js`
- `api/la/update.js`
- `api/la/end.js`
- `api/la/health.js`

### 3. Configuration
- `vercel.json` ✅ **CRITICAL - Cron schedule**

## Key Fixes in These Files

**Cron endpoint (`send-silent-push`) includes:**
- ✅ `apns_push_type_override: 'background'`
- ✅ `ios_interruption_level: 'passive'`
- ✅ `mutable_content: false`
- ✅ `priority: 5` (background priority)
- ✅ `ttl: 300` (increased from 180)

## Next Steps

1. Clone `petl-live-la` repository
2. Copy the files listed above
3. Commit and push to trigger Vercel deployment

