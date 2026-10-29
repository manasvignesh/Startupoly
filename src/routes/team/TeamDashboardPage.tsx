import React from 'react';
import { Navigate } from 'react-router-dom';
import { useMyTeam } from '../../data/useMyTeam';
import { ConnectionPill, StatusPill, Skeleton, PixelCard } from '../../ui';
import { LobbyWaitView } from './LobbyWaitView';
import { ActiveDashboardView } from './ActiveDashboardView';
import { GameOverView } from './GameOverView';
import { FinalBoardView } from './FinalBoardView';
import { TeamScene } from './TeamScene';
import { PropertySoldModal } from './PropertySoldModal';
import { useRoomBroadcast, PropertySoldEvent } from '../../data/broadcast';
import { STORAGE_KEY_TEAM_CLAIM } from '../../data/useMyTeam';

export const TeamDashboardPage: React.FC = () => {
  const {
    state,
    status,
    refetch,
    connection,
    lastUpdatedAt,
    isStale,
    staleAgeSeconds,
    cashFlash,
    wasClaimReleased,
    isSessionLost,
  } = useMyTeam();

  const [soldEvent, setSoldEvent] = React.useState<PropertySoldEvent | null>(null);

  // Retrieve room code from active team claim in localStorage
  const roomCode = React.useMemo(() => {
    try {
      if (typeof window !== 'undefined') {
        const raw = localStorage.getItem(STORAGE_KEY_TEAM_CLAIM);
        if (raw) {
          const parsed = JSON.parse(raw);
          return parsed?.code as string | undefined;
        }
      }
    } catch {}
    return undefined;
  }, []);

  // Listen to Supabase Realtime broadcast for any property acquired in the room
  useRoomBroadcast(roomCode, (event) => {
    setSoldEvent(event);
  });

  // Dual-layer fallback: if own team businesses array increases and broadcast wasn't caught
  const prevBizCountRef = React.useRef<number | null>(null);
  React.useEffect(() => {
    if (!state?.businesses) return;
    if (prevBizCountRef.current !== null && state.businesses.length > prevBizCountRef.current) {
      const newestBiz = state.businesses[state.businesses.length - 1];
      if (newestBiz) {
        setSoldEvent((current) => {
          if (current?.businessKey === newestBiz.business_key && Date.now() - current.timestamp < 6000) {
            return current;
          }
          return {
            teamName: state.team.name,
            teamColor: state.team.color,
            businessKey: newestBiz.business_key,
            businessName: newestBiz.name,
            cost: newestBiz.cost,
            timestamp: Date.now(),
          };
        });
      }
    }
    prevBizCountRef.current = state.businesses.length;
  }, [state?.businesses, state?.team.name, state?.team.color]);

  // Prevent accidental gestures or browser reload quitting active match
  React.useEffect(() => {
    if (state?.room.status === 'ACTIVE' || state?.room.status === 'LOBBY') {
      const handleBeforeUnload = (e: BeforeUnloadEvent) => {
        e.preventDefault();
        e.returnValue = '';
      };
      window.addEventListener('beforeunload', handleBeforeUnload);
      return () => window.removeEventListener('beforeunload', handleBeforeUnload);
    }
  }, [state?.room.status]);

  // If anonymous session was lost, redirect to /join with notice
  if (isSessionLost) {
    return (
      <Navigate
        to="/join"
        state={{ notice: 'Session expired. Please rejoin with your room code and PIN.' }}
        replace
      />
    );
  }

  // If claim was released by admin, redirect to /join with notice
  if (wasClaimReleased) {
    return (
      <Navigate
        to="/join"
        state={{ notice: 'Ask the organiser to rejoin you' }}
        replace
      />
    );
  }

  // If initial load in progress, show skeleton (never flash join screen)
  if (status === 'loading' && !state) {
    return (
      <div className="min-h-screen bg-nes-sky flex flex-col justify-between p-4">
        <header className="bg-nes-navy p-3 border-4 border-nes-navy shadow-[3px_3px_0px_var(--color-nes-navy)] flex items-center justify-between">
          <Skeleton height={20} width={120} />
          <Skeleton height={20} width={60} />
        </header>

        <main className="max-w-md w-full mx-auto my-auto flex flex-col gap-4">
          <PixelCard title="SYNCING TEAM DATA..." headerBg="navy">
            <div className="flex flex-col gap-3 py-4">
              <Skeleton height={60} />
              <div className="grid grid-cols-2 gap-3">
                <Skeleton height={80} />
                <Skeleton height={80} />
              </div>
              <Skeleton height={120} />
            </div>
          </PixelCard>
        </main>

        <div className="h-6 nes-brick-pattern border-t-4 border-nes-navy" />
      </div>
    );
  }

  // If ready and no team claim exists on this session, redirect to /join
  if (!state && status === 'ready') {
    return <Navigate to="/join" replace />;
  }

  if (!state) {
    return <Navigate to="/join" replace />;
  }

  const { team, room } = state;

  return (
    <div className="relative isolate min-h-screen bg-[linear-gradient(to_bottom,var(--color-brand-sky),var(--color-sky-horizon))] flex flex-col justify-between selection:bg-brand-gold selection:text-brand-navy">
      <TeamScene />

      <header className="sticky top-0 z-20 bg-brand-navy text-white border-b-2 border-brand-navy px-3 py-2 sm:px-5 flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          <span className="font-pixel text-xs font-extrabold tracking-widest text-brand-gold hidden sm:block">
            STARTUPOLY
          </span>
          <span aria-hidden="true" className="hidden sm:block h-5 w-px bg-white/30" />
          <span
            aria-hidden="true"
            className="w-4 h-4 rounded-sm border-2 border-white shrink-0"
            style={{ backgroundColor: team.color }}
          />
          <span className="font-pixel text-sm font-bold text-white truncate">{team.name}</span>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <ConnectionPill status={connection} lastUpdated={lastUpdatedAt} showLabel={false} />
          <StatusPill status={room.status} size="sm" />
        </div>
      </header>

      {/* Offline / Reconnecting Banner (> 20s stale) */}
      {isStale && (
        <div
          role="status"
          className="relative z-10 bg-status-warning-bg text-status-warning-text border-b-2 border-brand-navy px-3 py-1.5 text-center font-mono text-xs font-bold"
        >
          ⚠ Reconnecting… last update {staleAgeSeconds}s ago (values preserved)
        </div>
      )}

      <main className="relative z-10 flex-1 w-full max-w-3xl mx-auto p-3 sm:p-6 flex flex-col gap-4">
        {room.status === 'LOBBY' && <LobbyWaitView state={state} />}

        {room.status === 'ACTIVE' && (
          <ActiveDashboardView
            state={state}
            onExpire={() => refetch()}
            cashFlash={cashFlash}
          />
        )}

        {room.status === 'TIME_EXPIRED' && <GameOverView state={state} />}

        {room.status === 'FINALIZED' && <FinalBoardView state={state} />}
      </main>

      {/* Brick Ground Base Strip */}
      <div aria-hidden="true" className="relative z-10 h-6 nes-brick-pattern border-t-4 border-brand-navy" />

      {/* Property Acquired Celebration Modal */}
      <PropertySoldModal event={soldEvent} onDismiss={() => setSoldEvent(null)} />
    </div>
  );
};
