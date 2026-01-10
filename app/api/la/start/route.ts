// Next.js App Router API Route: Start Live Activity
// Receives Live Activity start request from iOS app and forwards to OneSignal

import { NextRequest, NextResponse } from 'next/server';

export async function POST(request: NextRequest) {
  const timestamp = new Date().toISOString();
  console.log(`[LA/START] 📥 Request received at ${timestamp}`);

  // Security: Verify request has valid secret
  const secret = request.headers.get('x-petl-secret');
  const expectedSecret = process.env.PETL_SERVER_SECRET;

  if (!expectedSecret || secret !== expectedSecret) {
    console.error('[LA/START] ❌ Unauthorized - missing or invalid secret');
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const body = await request.json();
    const { activityId, laPushToken, contentState, meta } = body;

    console.log(`[LA/START] ✅ Valid request - activityId: ${activityId?.substring(0, 8)}..., tokenLength: ${laPushToken?.length || 0}, soc: ${contentState?.soc}, playerId: ${meta?.playerId?.substring(0, 8)}...`);
    console.log(`[LA/START] Push token format check - hex length: ${laPushToken?.length}, starts with: ${laPushToken?.substring(0, 8)}`);
    console.log(`[LA/START] Activity ID format: ${activityId}`);

    if (!activityId || !laPushToken || !contentState) {
      return NextResponse.json({ error: 'Missing required fields' }, { status: 400 });
    }

    // Get OneSignal credentials from environment
    const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID;
    const ONESIGNAL_REST_API_KEY = process.env.ONESIGNAL_REST_API_KEY;

    if (!ONESIGNAL_APP_ID || !ONESIGNAL_REST_API_KEY) {
      console.error('[LA/START] Missing OneSignal credentials');
      return NextResponse.json({ error: 'Server configuration error' }, { status: 500 });
    }

    // Get player_id from meta or use filters to find device
    const playerId = meta?.playerId;
    
    if (!playerId) {
      return NextResponse.json(
        { error: 'Missing playerId in meta' },
        { status: 400 }
      );
    }

    // Forward to OneSignal Live Activity API
    // Format matches iOS app's OneSignalClient.swift implementation
    console.log(`[LA/START] 📤 Forwarding to OneSignal for activity ${activityId.substring(0, 8)}...`);
    const response = await fetch(
      `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify({
          push_token: laPushToken,
          name: 'petl-la-update',
          event_updates: {
            soc: contentState.soc,
            watts: contentState.watts,
            timeToFullMinutes: contentState.timeToFullMinutes,
            isCharging: contentState.isCharging
          },
          priority: 5
        })
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error('[LA/START] ❌ OneSignal API error:', JSON.stringify(result, null, 2));
      console.error('[LA/START] Response status:', response.status);
      console.error('[LA/START] Push token length:', laPushToken?.length || 0);
      console.error('[LA/START] Activity ID:', activityId);
      return NextResponse.json(
        { error: 'OneSignal API error', details: result },
        { status: response.status }
      );
    }

    console.log(`[LA/START] ✅ OneSignal API success - activity registered`);
    console.log(`[LA/START] OneSignal response:`, JSON.stringify(result, null, 2));

    // Store activity_id as a data tag on the player for cron job lookup
    // This allows the cron job to find which devices have active Live Activities
    try {
      const tagUrl = `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/players/${playerId}`;
      const tagBody = {
        app_id: ONESIGNAL_APP_ID,  // OneSignal requires app_id in body
        tags: {
          la_activity_id: activityId,
          la_push_token: laPushToken,
          charging: 'true'
        }
      };
      
      console.log(`[LA/START] Setting tags for player ${playerId.substring(0, 8)}... activity ${activityId.substring(0, 8)}...`);
      console.log(`[LA/START] Tag URL: ${tagUrl}`);
      console.log(`[LA/START] Tag body:`, JSON.stringify(tagBody, null, 2));
      
      const tagResponse = await fetch(tagUrl, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        },
        body: JSON.stringify(tagBody)
      });

      if (!tagResponse.ok) {
        const tagError = await tagResponse.json();
        console.error('[LA/START] ⚠️ Failed to set activity_id tag:', JSON.stringify(tagError, null, 2));
        console.error('[LA/START] Tag response status:', tagResponse.status, tagResponse.statusText);
        console.error('[LA/START] Player ID used:', playerId);
        // Don't fail the request if tag update fails - Live Activity is still registered
      } else {
        const tagResult = await tagResponse.json().catch(() => ({}));
        console.log(`[LA/START] ✅ Stored activity_id ${activityId.substring(0, 8)}... and push_token as tags for player ${playerId.substring(0, 8)}...`);
        console.log(`[LA/START] Tag update result:`, JSON.stringify(tagResult, null, 2));
      }
    } catch (tagError) {
      console.error('[LA/START] ❌ Error setting activity_id tag:', tagError);
      console.error('[LA/START] Error details:', tagError instanceof Error ? tagError.message : String(tagError));
      // Continue - Live Activity registration succeeded
    }

    console.log(`[LA/START] ✅ Successfully completed - returning 200 OK`);
    return NextResponse.json({
      success: true,
      activityId,
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    console.error('[LA/START] Error:', error);
    return NextResponse.json(
      { error: 'Failed to start Live Activity', message: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}

