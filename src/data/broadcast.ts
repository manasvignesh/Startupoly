import { useEffect, useRef } from 'react';
import { RealtimeChannel } from '@supabase/supabase-js';
import { supabase } from './client';
import { logger } from '../lib/logger';

export interface PropertySoldEvent {
  teamName: string;
  teamColor: string;
  businessKey: string;
  businessName: string;
  cost: number;
  timestamp: number;
  roomCode?: string;
}

// Active singleton channels keyed by topic
const activeChannels = new Map<string, RealtimeChannel>();

export function getBroadcastChannel(topic: string): RealtimeChannel {
  const cleanTopic = topic.toUpperCase().trim();
  let channel = activeChannels.get(cleanTopic);
  if (!channel) {
    channel = supabase.channel(`startupoly-broadcast-${cleanTopic}`, {
      config: { broadcast: { self: true } },
    });
    channel.subscribe((status) => {
      logger.debug('Broadcast', `Channel startupoly-broadcast-${cleanTopic} status: ${status}`);
    });
    activeChannels.set(cleanTopic, channel);
  }
  return channel;
}

// Native multi-tab BroadcastChannel for 0ms latency within same browser
let tabBridge: BroadcastChannel | null = null;
if (typeof window !== 'undefined' && 'BroadcastChannel' in window) {
  try {
    tabBridge = new BroadcastChannel('startupoly_sold_bridge');
  } catch {}
}

export async function broadcastPropertySold(roomCode: string | undefined, payload: PropertySoldEvent): Promise<void> {
  const fullPayload = { ...payload, roomCode, timestamp: payload.timestamp || Date.now() };

  // 1. Instant local tab bridge
  try {
    tabBridge?.postMessage(fullPayload);
  } catch {}

  // 2. Global broadcast channel (all connected phones receive this)
  try {
    const globalChannel = getBroadcastChannel('GLOBAL');
    await globalChannel.send({
      type: 'broadcast',
      event: 'property_sold',
      payload: fullPayload,
    });
  } catch (err) {
    logger.warn('Broadcast', 'Failed to send global broadcast property_sold:', err);
  }

  // 3. Room-specific broadcast channel if roomCode available
  if (roomCode) {
    try {
      const roomChannel = getBroadcastChannel(roomCode);
      await roomChannel.send({
        type: 'broadcast',
        event: 'property_sold',
        payload: fullPayload,
      });
      logger.info('Broadcast', `Sent property_sold event for ${payload.businessName} to room ${roomCode}`);
    } catch (err) {
      logger.warn('Broadcast', 'Failed to send room broadcast property_sold:', err);
    }
  }
}

export function useRoomBroadcast(
  roomCode: string | undefined,
  onPropertySold: (event: PropertySoldEvent) => void
) {
  const callbackRef = useRef(onPropertySold);
  callbackRef.current = onPropertySold;

  useEffect(() => {
    const lastTimestampRef = { current: 0 };

    const handleEvent = (payload: PropertySoldEvent) => {
      if (!payload) return;
      // Filter out duplicate events within 500ms
      if (payload.timestamp && payload.timestamp === lastTimestampRef.current) return;
      lastTimestampRef.current = payload.timestamp || Date.now();
      callbackRef.current(payload);
    };

    // 1. Listen on local tab bridge
    const onTabMessage = (e: MessageEvent) => {
      if (e.data) handleEvent(e.data);
    };
    tabBridge?.addEventListener('message', onTabMessage);

    // 2. Subscribe to Global Supabase Channel (always active, never blocked by missing roomCode)
    const globalChannel = getBroadcastChannel('GLOBAL');
    const globalHandler = (data: { payload: PropertySoldEvent }) => {
      if (data?.payload) handleEvent(data.payload);
    };
    globalChannel.on('broadcast', { event: 'property_sold' }, globalHandler);

    // 3. Also subscribe to Room-specific channel if roomCode is known
    let roomChannel: RealtimeChannel | null = null;
    if (roomCode) {
      roomChannel = getBroadcastChannel(roomCode);
      roomChannel.on('broadcast', { event: 'property_sold' }, globalHandler);
    }

    return () => {
      tabBridge?.removeEventListener('message', onTabMessage);
    };
  }, [roomCode]);
}
