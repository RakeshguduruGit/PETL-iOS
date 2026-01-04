# Vercel + OneSignal Integration Synchronization

This document ensures the PETL iOS app, Vercel API routes, and GitHub repository are synchronized.

## API Endpoints

All endpoints are deployed at: `https://petl-live-la.vercel.app`

### Live Activity Endpoints (Next.js App Router)

1. **POST `/api/la/start`**
   - iOS sends: `{ activityId, laPushToken, contentState, meta }`
   - Header: `X-PETL-Secret` (from Info.plist `PETLServerSecret`)
   - Forwards to OneSignal Live Activity API

2. **POST `/api/la/update`**
   - iOS sends: `{ activityId, contentState, ttlSeconds, meta }`
   - Header: `X-PETL-Secret`
   - Updates existing Live Activity via OneSignal

3. **POST `/api/la/end`**
   - iOS sends: `{ activityId, immediate, meta }`
   - Header: `X-PETL-Secret`
   - Ends Live Activity via OneSignal

4. **POST `/api/la/health`**
   - iOS sends: `{ meta }`
   - Header: `X-PETL-Secret` (optional)
   - Health check endpoint

### Cron Job

**GET `/api/cron/send-silent-push`**
- Runs every 3 minutes via Vercel Cron
- Sends silent push to all devices with `charging:true` tag
- Header: `Authorization: Bearer ${CRON_SECRET}`

## OneSignal API Format

All Live Activity endpoints use:
- **Authorization**: `Key ${ONESIGNAL_REST_API_KEY}` (not `Basic`)
- **URL**: `https://api.onesignal.com/apps/{APP_ID}/live_activities/{activityId}/notifications`

### Update Format:
```json
{
  "event": "update",
  "name": "petl-la-update",
  "event_updates": {
    "soc": 85,
    "watts": 15.5,
    "timeToFullMinutes": 45,
    "isCharging": true
  },
  "priority": 5
}
```

### End Format:
```json
{
  "event": "end",
  "event_updates": {
    "soc": 0,
    "watts": 0.0,
    "timeToFullMinutes": 2,
    "isCharging": false
  },
  "dismissal_date": <timestamp>
}
```

## Environment Variables (Vercel)

Required in Vercel project settings:
- `PETL_SERVER_SECRET` - Secret key matching iOS app's Info.plist
- `ONESIGNAL_APP_ID` - OneSignal Application ID
- `ONESIGNAL_REST_API_KEY` - OneSignal REST API Key
- `CRON_SECRET` - Secret for cron job authentication

## iOS App Configuration

- **Base URL**: `https://petl-live-la.vercel.app` (set in `LiveActivityRemoteClient.swift`)
- **Secret**: Stored in `Info.plist` as `PETLServerSecret`
- **Endpoints**: `/api/la/start`, `/api/la/update`, `/api/la/end`, `/api/la/health`

## File Structure

```
app/
  api/
    la/
      start/route.ts    # Next.js App Router format
      update/route.ts
      end/route.ts
      health/route.ts
    cron/
      send-silent-push/route.ts  # (should exist in Vercel project)

api/                          # Traditional Vercel format (backup)
  la/
    start.js
    update.js
    end.js
    health.js
  cron/
    send-silent-push.js

vercel.json                   # Cron job configuration
```

## Deployment

1. Push changes to GitHub
2. Vercel automatically deploys from GitHub
3. Verify endpoints respond correctly
4. Test from iOS app

## Synchronization Checklist

- [x] iOS app uses correct base URL
- [x] All endpoint paths match iOS app expectations
- [x] OneSignal API format matches iOS app implementation
- [x] Authorization header format correct (`Key` not `Basic`)
- [x] All required environment variables documented
- [x] Cron job path matches Vercel configuration
- [x] Request/response contracts match between iOS and Vercel

