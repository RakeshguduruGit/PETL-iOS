// Next.js App Router API Route: Update Live Activity
// Receives Live Activity update request from iOS app and forwards to OneSignal

import { NextRequest, NextResponse } from 'next/server';

export async function POST(request: NextRequest) {
  const timestamp = new Date().toISOString();
  console.log(`[LA/UPDATE] 📥 Request received at ${timestamp}`);

  // Security: Verify request has valid secret
  const secret = request.headers.get('x-petl-secret');
  const expectedSecret = process.env.PETL_SERVER_SECRET;

  if (!expectedSecret || secret !== expectedSecret) {
    console.error('[LA/UPDATE] ❌ Unauthorized - missing or invalid secret');
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const body = await request.json();
    const { activityId, contentState, ttlSeconds, meta } = body;

    console.log(`[LA/UPDATE] ✅ Valid request - activityId: ${activityId?.substring(0, 8)}..., soc: ${contentState?.soc}, watts: ${contentState?.watts}, eta: ${contentState?.timeToFullMinutes}, playerId: ${meta?.playerId?.substring(0, 8)}...`);

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

    // Get player_id from meta to retrieve stored push token
    const playerId = meta?.playerId;
    let pushToken: string | null = null;

    // Retrieve stored push token from player tags
    if (playerId) {
      try {
        const playerResponse = await fetch(
          `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/players/${playerId}?app_id=${ONESIGNAL_APP_ID}`,
          {
            method: 'GET',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
            }
          }
        );

        if (playerResponse.ok) {
          const playerData = await playerResponse.json();
          pushToken = playerData.tags?.la_push_token || null;
          if (!pushToken) {
            console.warn(`[LA/UPDATE] ⚠️ No stored push token found for player ${playerId.substring(0, 8)}..., activity ${activityId.substring(0, 8)}...`);
          } else {
            console.log(`[LA/UPDATE] ✅ Retrieved push token from player tags (length: ${pushToken.length})`);
          }
        } else {
          const errorData = await playerResponse.json().catch(() => ({}));
          console.warn(`[LA/UPDATE] ⚠️ Failed to retrieve player data: ${playerResponse.status}`, JSON.stringify(errorData, null, 2));
        }
      } catch (playerError) {
        console.error('[LA/UPDATE] Error retrieving player data:', playerError);
        // Continue - we'll try without push token (may fail, but won't crash)
      }
    }

    if (!pushToken) {
      console.error(`[LA/UPDATE] ❌ Push token not found - cannot send update`);
      return NextResponse.json(
        { error: 'Push token not found. Live Activity may not have been started properly.' },
        { status: 400 }
      );
    }

    // Forward to OneSignal Live Activity API
    // Format matches iOS app's OneSignalClient.swift implementation
    console.log(`[LA/UPDATE] 📤 Forwarding to OneSignal for activity ${activityId.substring(0, 8)}... (soc: ${contentState.soc}, watts: ${contentState.watts}, eta: ${contentState.timeToFullMinutes})`);
    const response = await fetch(
      `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify({
          push_token: pushToken,
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
      console.error('[LA/UPDATE] ❌ OneSignal API error:', JSON.stringify(result, null, 2));
      return NextResponse.json(
        { error: 'OneSignal API error', details: result },
        { status: response.status }
      );
    }

    console.log(`[LA/UPDATE] ✅ OneSignal API success - update delivered`);

    // Store last known values in player tags so cron job can use them
    if (playerId) {
      try {
        await fetch(
          `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/players/${playerId}`,
          {
            method: 'PUT',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
            },
            body: JSON.stringify({
              tags: {
                last_soc: contentState.soc.toString(),
                last_watts: contentState.watts.toString(),
                last_eta: contentState.timeToFullMinutes.toString()
              }
            })
          }
        );
      } catch (tagError) {
        // Non-critical - continue even if tag update fails
        console.error('[LA/UPDATE] Failed to update tags:', tagError);
      }
    }

    console.log(`[LA/UPDATE] ✅ Successfully completed - returning 200 OK`);
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

