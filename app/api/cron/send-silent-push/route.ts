// Next.js App Router API Route: Send periodic silent push to all charging devices
// This is called by Vercel Cron every 3 minutes (recommended: 10-15 minutes)

import { NextRequest, NextResponse } from 'next/server';

export async function GET(request: NextRequest) {
  // Security: Verify this is actually a cron job (not a random user request)
  const authHeader = request.headers.get('authorization');
  const cronSecret = process.env.CRON_SECRET;

  if (!cronSecret || authHeader !== `Bearer ${cronSecret}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  // Get OneSignal credentials from environment
  const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
  const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

  if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
    console.error('[CRON] Missing OneSignal credentials');
    return NextResponse.json(
      {
        error: 'Missing OneSignal credentials',
        hasAppId: !!ONESIGNAL_APP_ID,
        hasRestKey: !!ONESIGNAL_REST_API_KEY
      },
      { status: 500 }
    );
  }

  try {
    console.log('[CRON] Sending silent push to all charging devices...');

    // Send silent push to all devices with "charging:true" tag
    // CRITICAL: Must use proper APNs background push headers for iOS to wake the app
    const response = await fetch('https://api.onesignal.com/notifications', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Basic ${ONESIGNAL_REST_API_KEY}`
      },
      body: JSON.stringify({
        app_id: ONESIGNAL_APP_ID,
        filters: [
          { field: 'tag', key: 'charging', relation: '=', value: 'true' }
        ],
        content_available: true,
        // CRITICAL: These headers tell APNs this is a background push
        apns_push_type_override: 'background',
        ios_interruption_level: 'passive',
        mutable_content: false,
        // Background priority (5), not high priority (10)
        priority: 5,
        data: {
          type: 'petl-bg-update',
          timestamp: new Date().toISOString()
        },
        ttl: 300  // 5 minutes TTL (increased for better delivery)
      })
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('[CRON] OneSignal API error:', result);
      return NextResponse.json(
        {
          error: 'OneSignal API error',
          details: result
        },
        { status: response.status }
      );
    }

    const recipients = result.recipients || 0;
    console.log(`[CRON] Success: Sent to ${recipients} recipient(s)`);

    return NextResponse.json({
      success: true,
      timestamp: new Date().toISOString(),
      recipients,
      notificationId: result.id
    });

  } catch (error) {
    console.error('[CRON] Error sending silent push:', error);
    return NextResponse.json(
      {
        error: 'Failed to send push',
        message: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}

