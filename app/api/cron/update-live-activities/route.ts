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
    const activePlayers = allPlayers.filter((player: any) => {
      const tags = player.tags || {};
      const hasCharging = tags.charging === 'true';
      const hasActivityId = tags.la_activity_id && tags.la_activity_id.trim() !== '';
      return hasCharging && hasActivityId;
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
      
      if (!activityId || !pushToken) {
        console.warn(`[Cron] ⚠️ Player ${player.id.substring(0, 8)}... missing activityId or push_token`);
        console.warn(`[Cron] Player tags:`, JSON.stringify(player.tags || {}, null, 2));
        updateResults.push({
          playerId: player.id,
          activityId: activityId || 'unknown',
          success: false,
          error: 'Missing activityId or push_token'
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
        
        const payload: any = {
          push_token: pushToken,  // ✅ CRITICAL: Include push token!
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

        // Safety check: Ensure push_token is included
        if (!payload.push_token) {
          console.error(`[Cron] ❌ CRITICAL: push_token is missing from payload! pushToken value: ${pushToken}`);
          throw new Error('push_token is required but missing');
        }

        console.log(`[OneSignal update] Payload keys: ${Object.keys(payload).join(', ')}`);
        console.log(`[OneSignal update] Payload push_token length: ${payload.push_token?.length || 0}`);
        console.log(`[OneSignal update] Payload: ${JSON.stringify(payload)}`);

        const response = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Key ${ONESIGNAL_REST_API_KEY}`
          },
          body: JSON.stringify(payload)
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
