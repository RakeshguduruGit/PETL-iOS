// Next.js App Router API Route: Update Live Activities directly via OneSignal
// This is called by Vercel Cron every 3 minutes
// Directly updates Live Activities via OneSignal API using stored push tokens
// Reference: https://documentation.onesignal.com/docs/en/live-activities-developer-setup

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
    console.log('[Cron] Starting direct Live Activity updates...');

    // Query OneSignal for players with charging:true AND la_activity_id tag (indicating active LA)
    let allPlayers: any[] = [];
    let offset = 0;
    const limit = 100;
    let hasMore = true;

    while (hasMore) {
      const url = `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/players?app_id=${ONESIGNAL_APP_ID}&limit=${limit}&offset=${offset}`;
      console.log(`[Cron] Fetching players from OneSignal: offset=${offset}, limit=${limit}`);
      
      const viewResponse = await fetch(url, {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
        }
      });

      if (!viewResponse.ok) {
        const errorData = await viewResponse.json().catch(() => ({ error: 'Failed to parse error response' }));
        console.error('[Cron] ❌ Failed to fetch players:', JSON.stringify(errorData, null, 2));
        console.error('[Cron] Response status:', viewResponse.status, viewResponse.statusText);
        break;
      }

      const playersData = await viewResponse.json();
      const players = playersData.players || [];
      
      console.log(`[Cron] Fetched ${players.length} players (offset: ${offset}, total so far: ${allPlayers.length})`);
      
      if (players.length === 0) {
        hasMore = false;
      } else {
        allPlayers = allPlayers.concat(players);
        offset += limit;
        if (offset >= 1000) {
          hasMore = false;
        }
      }
    }

    console.log(`[Cron] Total players fetched: ${allPlayers.length}`);

    // Debug: Log sample of player tags to see what we're getting
    if (allPlayers.length > 0) {
      const samplePlayer = allPlayers[0];
      console.log(`[Cron] Sample player tags:`, JSON.stringify(samplePlayer.tags || {}, null, 2));
      console.log(`[Cron] Sample player has charging tag: ${samplePlayer.tags?.charging}`);
      console.log(`[Cron] Sample player has la_activity_id tag: ${samplePlayer.tags?.la_activity_id}`);
    }

    // Filter players with charging:true and la_activity_id tag
    console.log(`[Cron] Filtering ${allPlayers.length} players for active Live Activities...`);
    const activePlayers = allPlayers.filter((player: any) => {
      const tags = player.tags || {};
      const hasCharging = tags.charging === 'true';
      const hasActivityId = tags.la_activity_id && tags.la_activity_id.trim() !== '';
      const hasPushToken = tags.la_push_token && tags.la_push_token.trim() !== '';
      
      // Log filter details for first few players
      if (allPlayers.indexOf(player) < 3) {
        console.log(`[Cron] Player ${player.id.substring(0, 8)}... - charging:${hasCharging}, activityId:${hasActivityId}, pushToken:${hasPushToken}`);
        console.log(`[Cron] Player ${player.id.substring(0, 8)}... tags:`, JSON.stringify({
          charging: tags.charging,
          la_activity_id: tags.la_activity_id?.substring(0, 12) || 'MISSING',
          la_push_token: tags.la_push_token ? `${tags.la_push_token.substring(0, 8)}... (${tags.la_push_token.length} chars)` : 'MISSING'
        }));
      }
      
      return hasCharging && hasActivityId && hasPushToken;  // Also require push token
    });

    console.log(`[SessionStore] Found ${activePlayers.length} active activities (total: ${activePlayers.length})`);
    console.log(`[Cron] Found ${activePlayers.length} active activities to update`);
    
    // Debug: If no active players, show why
    if (activePlayers.length === 0 && allPlayers.length > 0) {
      const playersWithCharging = allPlayers.filter((p: any) => p.tags?.charging === 'true');
      const playersWithActivityId = allPlayers.filter((p: any) => p.tags?.la_activity_id && p.tags.la_activity_id.trim() !== '');
      console.log(`[Cron] Debug: ${playersWithCharging.length} players have charging:true`);
      console.log(`[Cron] Debug: ${playersWithActivityId.length} players have la_activity_id`);
    }

    if (activePlayers.length === 0) {
      // Provide helpful diagnostic information
      const diagnosticInfo: any = {
        success: true,
        timestamp: new Date().toISOString(),
        updated: 0,
        message: 'No active Live Activities to update',
        diagnostic: {
          totalPlayersFetched: allPlayers.length,
          playersWithChargingTag: allPlayers.filter((p: any) => p.tags?.charging === 'true').length,
          playersWithActivityIdTag: allPlayers.filter((p: any) => p.tags?.la_activity_id && p.tags.la_activity_id.trim() !== '').length,
          samplePlayerTags: allPlayers.length > 0 ? Object.keys(allPlayers[0]?.tags || {}) : []
        }
      };
      console.log('[Cron] Diagnostic info:', JSON.stringify(diagnosticInfo.diagnostic, null, 2));
      return NextResponse.json(diagnosticInfo);
    }

    console.log(`[OneSignal update] App ID prefix: ${ONESIGNAL_APP_ID.substring(0, 8)}...`);
    console.log(`[OneSignal update] Has REST key: ${!!ONESIGNAL_REST_API_KEY}`);

    const updateResults = [];
    
    // Update each active Live Activity directly via OneSignal
    for (const player of activePlayers) {
      const activityId = player.tags?.la_activity_id;
      const pushToken = player.tags?.la_push_token;
      
      console.log(`[Cron] Processing player ${player.id.substring(0, 8)}... activityId: ${activityId?.substring(0, 8) || 'MISSING'}... pushToken: ${pushToken ? `${pushToken.substring(0, 8)}... (len: ${pushToken.length})` : 'MISSING'}`);
      console.log(`[Cron] Player tags available:`, JSON.stringify(Object.keys(player.tags || {})));
      console.log(`[Cron] la_activity_id tag: ${player.tags?.la_activity_id || 'MISSING'}`);
      console.log(`[Cron] la_push_token tag: ${player.tags?.la_push_token ? `${player.tags.la_push_token.substring(0, 8)}... (len: ${player.tags.la_push_token.length})` : 'MISSING'}`);
      
      // More strict validation: check for truthy and non-empty string
      if (!activityId || !activityId.trim() || !pushToken || !pushToken.trim()) {
        console.warn(`[Cron] ⚠️ Player ${player.id.substring(0, 8)}... missing activityId or push_token`);
        console.warn(`[Cron] activityId: "${activityId}" (length: ${activityId?.length || 0})`);
        console.warn(`[Cron] pushToken: "${pushToken?.substring(0, 20) || 'MISSING'}" (length: ${pushToken?.length || 0})`);
        console.warn(`[Cron] Player tags:`, JSON.stringify(player.tags || {}, null, 2));
        updateResults.push({
          playerId: player.id,
          activityId: activityId || 'unknown',
          success: false,
          error: `Missing activityId or push_token (activityId: ${!!activityId}, pushToken: ${!!pushToken})`
        });
        continue;
      }

      // Get latest state from player tags (soc, watts, eta)
      const soc = parseInt(player.tags?.last_soc || player.tags?.soc || '0', 10);
      const watts = parseFloat(player.tags?.last_watts || player.tags?.watts || '0');
      const timeToFullMinutes = parseInt(player.tags?.last_eta || player.tags?.eta || '0', 10);
      const isCharging = player.tags?.charging === 'true';

      try {
        const url = `https://api.onesignal.com/apps/${ONESIGNAL_APP_ID}/live_activities/${activityId}/notifications`;
        console.log(`[OneSignal update] URL: ${url}`);
        
        // Verify pushToken exists and is valid before creating payload
        if (!pushToken || typeof pushToken !== 'string' || pushToken.trim().length === 0) {
          console.error(`[Cron] ❌ CRITICAL: pushToken is invalid! Value: "${pushToken}", Type: ${typeof pushToken}`);
          throw new Error(`Invalid push_token: ${pushToken}`);
        }

        const payload: any = {
          push_token: pushToken.trim(),  // ✅ CRITICAL: Include push token!
          event: 'update',
          name: 'petl-la-update',
          event_updates: {
            soc: soc,
            watts: watts,
            timeToFullMinutes: Math.max(0, timeToFullMinutes),
            isCharging: isCharging
          },
          priority: 5
        };

        // Safety check: Ensure push_token is included and valid
        if (!payload.push_token || payload.push_token.length < 32) {
          console.error(`[Cron] ❌ CRITICAL: push_token is missing or invalid in payload!`);
          console.error(`[Cron] push_token value: "${payload.push_token}", length: ${payload.push_token?.length || 0}`);
          console.error(`[Cron] Original pushToken: "${pushToken}", length: ${pushToken?.length || 0}`);
          throw new Error('push_token is required but missing or invalid');
        }

        // Verify payload structure before sending
        const payloadKeys = Object.keys(payload);
        const hasPushToken = 'push_token' in payload && payload.push_token && payload.push_token.length > 0;
        
        console.log(`[OneSignal update] Payload keys: ${payloadKeys.join(', ')}`);
        console.log(`[OneSignal update] Payload has push_token key: ${'push_token' in payload}`);
        console.log(`[OneSignal update] Payload push_token present: ${hasPushToken}`);
        console.log(`[OneSignal update] Payload push_token length: ${payload.push_token?.length || 0}`);
        
        if (!hasPushToken) {
          console.error(`[Cron] ❌ CRITICAL ERROR: push_token is MISSING from payload object!`);
          console.error(`[Cron] Payload object:`, JSON.stringify(payload, null, 2));
          console.error(`[Cron] pushToken variable:`, pushToken);
          throw new Error('push_token is missing from payload - this should never happen');
        }

        // Serialize payload to verify it includes push_token
        const serializedPayload = JSON.stringify(payload);
        const parsedPayload = JSON.parse(serializedPayload);
        if (!parsedPayload.push_token) {
          console.error(`[Cron] ❌ CRITICAL: push_token lost during JSON serialization!`);
          throw new Error('push_token lost during JSON serialization');
        }
        
        console.log(`[OneSignal update] ✅ Payload verified - push_token present (length: ${payload.push_token.length})`);
        console.log(`[OneSignal update] Payload preview (first 200 chars): ${serializedPayload.substring(0, 200)}...`);

        const response = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
          },
          body: serializedPayload  // Use pre-serialized payload to ensure push_token is included
        });

        const result = await response.json();
        console.log(`[OneSignal update] Response: ${response.status} ${response.statusText}`);
        console.log(`[OneSignal update] Response body: ${JSON.stringify(result)}`);

        if (response.ok) {
          console.log(`[OneSignal update] Success - Response ID: ${result.id || 'unknown'}`);
          console.log(`[Cron] Updated activityId=${activityId.substring(0, 8)}... soc=${soc}%`);
          updateResults.push({
            playerId: player.id,
            activityId: activityId,
            success: true,
            responseId: result.id
          });
        } else {
          console.error(`[OneSignal update] ❌ Error: ${JSON.stringify(result, null, 2)}`);
          updateResults.push({
            playerId: player.id,
            activityId: activityId,
            success: false,
            error: result
          });
        }
      } catch (error) {
        console.error(`[Cron] Error updating activity ${activityId.substring(0, 8)}...:`, error);
        updateResults.push({
          playerId: player.id,
          activityId: activityId,
          success: false,
          error: error instanceof Error ? error.message : 'Unknown error'
        });
      }
    }

    const successful = updateResults.filter(r => r.success).length;
    const failed = updateResults.filter(r => !r.success).length;

    console.log(`[Cron] Completed: ${successful} succeeded, ${failed} failed out of ${activePlayers.length} total`);

    return NextResponse.json({
      success: true,
      timestamp: new Date().toISOString(),
      updated: successful,
      failed,
      total: activePlayers.length,
      results: updateResults.slice(0, 10)
    });

  } catch (error) {
    console.error('[Cron] Error updating Live Activities:', error);
    return NextResponse.json(
      {
        error: 'Failed to update Live Activities',
        message: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}
