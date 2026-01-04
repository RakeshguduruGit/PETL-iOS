// Next.js App Router API Route: Health check endpoint
// Used by iOS app to verify server connectivity

import { NextRequest, NextResponse } from 'next/server';

export async function POST(request: NextRequest) {
  try {
    // Optional: Verify secret for health checks too
    const secret = request.headers.get('x-petl-secret');
    const expectedSecret = process.env.PETL_SERVER_SECRET;

    if (expectedSecret && secret !== expectedSecret) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const body = await request.json().catch(() => ({}));
    const { meta } = body || {};

    // Check if OneSignal credentials are configured
    const hasOneSignal = !!(process.env.ONESIGNAL_APP_ID && process.env.ONESIGNAL_REST_API_KEY);
    const hasSecret = !!process.env.PETL_SERVER_SECRET;

    return NextResponse.json({
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

  } catch (error) {
    return NextResponse.json(
      { error: 'Health check failed', message: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}

