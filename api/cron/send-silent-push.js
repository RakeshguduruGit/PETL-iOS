// Vercel Serverless Function: Send periodic silent push to all charging devices
// This is called by Vercel Cron every 3 minutes

export default async function handler(req, res) {
  // Security: Verify this is actually a cron job (not a random user request)
  const authHeader = req.headers.authorization;
  const cronSecret = process.env.CRON_SECRET;

  if (!cronSecret || authHeader !== `Bearer ${cronSecret}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  // Get OneSignal credentials from environment
  const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
  const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

  if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
    console.error('[CRON] Missing OneSignal credentials');
    return res.status(500).json({ 
      error: 'Missing OneSignal credentials',
      hasAppId: !!ONESIGNAL_APP_ID,
      hasRestKey: !!ONESIGNAL_REST_API_KEY
    });
  }

  try {
    console.log('[CRON] Sending silent push to all charging devices...');

    // Send silent push to all devices with "charging:true" tag
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
        data: {
          type: 'petl-bg-update',
          timestamp: new Date().toISOString()
        },
        priority: 10,
        ttl: 180
      })
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('[CRON] OneSignal API error:', result);
      return res.status(response.status).json({
        error: 'OneSignal API error',
        details: result
      });
    }

    const recipients = result.recipients || 0;
    console.log(`[CRON] Success: Sent to ${recipients} recipient(s)`);

    return res.status(200).json({
      success: true,
      timestamp: new Date().toISOString(),
      recipients,
      notificationId: result.id
    });

  } catch (error) {
    console.error('[CRON] Error sending silent push:', error);
    return res.status(500).json({
      error: 'Failed to send push',
      message: error.message
    });
  }
}

