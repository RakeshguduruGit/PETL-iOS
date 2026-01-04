// Next.js App Router API Route: End Live Activity
// Receives Live Activity end request from iOS app and forwards to OneSignal

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
    const { activityId, immediate, meta } = body;

    if (!activityId) {
      return NextResponse.json({ error: 'Missing activityId' }, { status: 400 });
    }

    // Get OneSignal credentials from environment
    const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
    const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

    if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
      console.error('[LA/END] Missing OneSignal credentials');
      return NextResponse.json({ error: 'Server configuration error' }, { status: 500 });
    }

    // Forward to OneSignal Live Activity API to end
    // Format matches iOS app's OneSignalClient.swift implementation
    const dismissalDate = immediate 
      ? Math.floor(Date.now() / 1000) - 5  // Force immediate dismissal
      : Math.floor(Date.now() / 1000);     // Normal dismissal
    
    const response = await fetch(
      `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify({
          event: 'end',
          // OneSignal requires event_updates even for end; send a minimal valid ContentState
          event_updates: {
            soc: 0,
            watts: 0.0,
            timeToFullMinutes: 2,
            isCharging: false
          },
          // Force immediate dismissal by setting a recent past timestamp
          dismissal_date: dismissalDate
        })
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error('[LA/END] OneSignal API error:', result);
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
    console.error('[LA/END] Error:', error);
    return NextResponse.json(
      { error: 'Failed to end Live Activity', message: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}

