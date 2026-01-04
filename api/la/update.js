// Vercel Serverless Function: Update Live Activity
// Receives Live Activity update request from iOS app and forwards to OneSignal

export default async function handler(req, res) {
  // Security: Verify request has valid secret
  const secret = req.headers['x-petl-secret'];
  const expectedSecret = process.env.PETL_SERVER_SECRET;

  if (!expectedSecret || secret !== expectedSecret) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { activityId, contentState, ttlSeconds, meta } = req.body;

  if (!activityId || !contentState) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  // Get OneSignal credentials from environment
  const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
  const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

  if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
    console.error('[LA/UPDATE] Missing OneSignal credentials');
    return res.status(500).json({ error: 'Server configuration error' });
  }

  try {
    // Forward to OneSignal Live Activity API
    const response = await fetch(
      `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Basic ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify({
          name: 'petl-charging',
          event: {
            update: {
              alert: {
                subtitle: {
                  content: `${contentState.soc}% • ${contentState.watts.toFixed(0)}W`
                }
              },
              sound: 'default'
            }
          },
          custom_data: {
            soc: contentState.soc,
            watts: contentState.watts,
            timeToFullMinutes: contentState.timeToFullMinutes,
            isCharging: contentState.isCharging
          }
        })
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error('[LA/UPDATE] OneSignal API error:', result);
      return res.status(response.status).json({
        error: 'OneSignal API error',
        details: result
      });
    }

    return res.status(200).json({
      success: true,
      activityId,
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    console.error('[LA/UPDATE] Error:', error);
    return res.status(500).json({
      error: 'Failed to update Live Activity',
      message: error.message
    });
  }
}

