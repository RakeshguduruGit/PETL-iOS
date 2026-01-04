// Next.js App Router API Route: Update Live Activity
// Receives Live Activity update request from iOS app and forwards to OneSignal

import { NextRequest, NextResponse } from 'next/server';

export async function POST(request: NextRequest) {
  // Security: Verify request has valid secret
  const secret = request.headers.get('x-petl-secret');
  const expectedSecret = process.env.PETL_SERVER_SECRET;

  if (!expectedSecret || secret !== expectedSecret) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const body = await request.json();
    const { activityId, contentState, ttlSeconds, meta } = body;

    if (!activityId || !contentState) {
      return NextResponse.json({ error: 'Missing required fields' }, { status: 400 });
    }

    // Get OneSignal credentials from environment
    const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
    const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

    if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
      console.error('[LA/UPDATE] Missing OneSignal credentials');
      return NextResponse.json({ error: 'Server configuration error' }, { status: 500 });
    }

    // Forward to OneSignal Live Activity API
    // Format matches iOS app's OneSignalClient.swift implementation
    const response = await fetch(
      `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify({
          event: 'update',
          name: 'petl-la-update',
          event_updates: {
            soc: contentState.soc,
            watts: contentState.watts,
            timeToFullMinutes: Math.max(0, contentState.timeToFullMinutes),
            isCharging: contentState.isCharging
          },
          priority: 5
        })
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error('[LA/UPDATE] OneSignal API error:', result);
      return NextResponse.json(
        { error: 'OneSignal API error', details: result },
        { status: response.status }
      );
    }

    return NextResponse.json({
      success: true,
      activityId,
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    console.error('[LA/UPDATE] Error:', error);
    return NextResponse.json(
      { error: 'Failed to update Live Activity', message: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}

