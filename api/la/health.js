// Vercel Serverless Function: Health check endpoint
// Used by iOS app to verify server connectivity

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // Optional: Verify secret for health checks too
  const secret = req.headers['x-petl-secret'];
  const expectedSecret = process.env.PETL_SERVER_SECRET;

  if (expectedSecret && secret !== expectedSecret) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const { meta } = req.body || {};

  // Check if OneSignal credentials are configured
  const hasOneSignal = !!(process.env.ONESIGNAL_APP_ID && process.env.ONESIGNAL_REST_API_KEY);
  const hasSecret = !!process.env.PETL_SERVER_SECRET;

  return res.status(200).json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    server: 'petl-live-la',
    version: '1.0.0',
    config: {
      hasOneSignal,
      hasSecret
    },
    meta: meta || null
  });
}

