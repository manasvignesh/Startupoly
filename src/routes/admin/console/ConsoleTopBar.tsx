import React from 'react';
import { Link } from 'react-router-dom';
import { Countdown, StatusPill, ConnectionPill } from '../../../ui';
import { ConnectionStatus } from '../../../ui/ConnectionPill';

export interface ConsoleTopBarProps {
  roomCode: string;
  status: string;
  endsAt: string | null;
  serverNow?: string | null;
  connection: ConnectionStatus;
  lastUpdated: string;
  onRefetch?: () => void;
  isRefetching?: boolean;
  onAbortGame?: () => void;
  onExtendTenMinutes?: () => void;
  isExtendingTime?: boolean;
  onFinalizeMatch?: () => void;
}

export const ConsoleTopBar: React.FC<ConsoleTopBarProps> = ({
  roomCode,
  status,
  endsAt,
  serverNow,
  connection,
  lastUpdated,
  onRefetch,
  isRefetching = false,
  onAbortGame,
  onExtendTenMinutes,
  isExtendingTime = false,
  onFinalizeMatch,
}) => {
  return (
    <header className="bg-brand-navy text-white border-b-4 border-brand-navy px-4 py-3 flex flex-wrap items-center justify-between gap-4 shadow-pixel select-none">
      {/* Left section: Navigation & Room Badge */}
      <div className="flex items-center gap-3">
        <Link
          to="/admin"
          className="font-pixel text-xs text-brand-gold hover:underline flex items-center gap-1.5 transition-colors"
        >
          <span>◄</span> CONSOLE
        </Link>
        <div className="border-l-2 border-white/20 pl-3 flex items-center gap-2">
          <span className="font-pixel text-xs text-brand-gold tracking-wider">
            ROOM {roomCode}
          </span>
          <StatusPill status={status} size="sm" />
        </div>
        {onAbortGame && status === 'ACTIVE' && (
          <div className="border-l-2 border-white/20 pl-3">
            <button
              type="button"
              onClick={onAbortGame}
              className="font-pixel text-[10px] bg-brand-red text-white px-2.5 py-1 border-2 border-white/30 hover:bg-interactive-red-hover active:translate-y-0.5 transition-colors cursor-pointer uppercase tracking-wider"
              title="Abort game and return to lobby"
            >
              ✕ ABORT
            </button>
          </div>
        )}
      </div>

      {/* Center section: Authoritative Server-Clock Countdown & Extra Time Action */}
      <div className="flex items-center gap-3">
        <div className="flex flex-col items-center justify-center bg-black/30 border-2 border-brand-gold/40 px-3.5 py-1 shadow-inner">
          <Countdown
            endsAt={endsAt}
            status={status}
            serverNow={serverNow}
            size="lg"
            showLabel={false}
            className="scale-90 sm:scale-100"
          />
          {status === 'TIME_EXPIRED' && (
            <span className="font-pixel text-[8px] sm:text-[9px] text-brand-gold tracking-wider uppercase drop-shadow-[1px_1px_0px_rgba(0,0,0,1)] animate-pulse">
              TIME UP · SCORES FROZEN
            </span>
          )}
        </div>

        {/* Quick +10m Extra Time Button */}
        {onExtendTenMinutes && (status === 'ACTIVE' || status === 'TIME_EXPIRED') && (
          <button
            type="button"
            disabled={isExtendingTime}
            onClick={onExtendTenMinutes}
            title="Add 10 minutes of extra time to this match"
            className="
              font-pixel text-[10px] bg-brand-green text-white px-2.5 py-1.5
              border-2 border-brand-navy shadow-pixel-sm hover:bg-interactive-green-hover
              active:translate-y-0.5 cursor-pointer flex items-center gap-1 font-bold uppercase transition-all
              disabled:opacity-50 disabled:cursor-not-allowed
            "
          >
            <span>⚡</span>
            <span>{isExtendingTime ? '+10M...' : '+10M TIME'}</span>
          </button>
        )}

        {/* Quick Finalize Match Button */}
        {onFinalizeMatch && (status === 'ACTIVE' || status === 'TIME_EXPIRED') && (
          <button
            type="button"
            onClick={onFinalizeMatch}
            title="Finalize match and lock tournament results at any time"
            className="
              font-pixel text-[10px] bg-brand-gold text-brand-navy px-2.5 py-1.5
              border-2 border-brand-navy shadow-pixel-sm hover:bg-yellow-400
              active:translate-y-0.5 cursor-pointer flex items-center gap-1 font-bold uppercase transition-all
            "
          >
            <span>🏆</span>
            <span>FINALIZE</span>
          </button>
        )}
      </div>

      {/* Right section: Connection & sync status */}
      <div className="flex items-center gap-3">
        <span className="hidden lg:inline font-mono text-[11px] text-neutral-400">
          Updated: {lastUpdated}
        </span>
        <ConnectionPill status={connection} lastUpdated={lastUpdated} />
        {onRefetch && (
          <button
            type="button"
            onClick={onRefetch}
            disabled={isRefetching}
            title="Refresh snapshot now"
            className="w-8 h-8 flex items-center justify-center bg-brand-cream text-brand-navy border-2 border-brand-navy font-pixel text-xs hover:bg-brand-gold transition-colors cursor-pointer disabled:opacity-50 active:translate-y-0.5 shadow-pixel-sm"
          >
            {isRefetching ? '…' : '↻'}
          </button>
        )}
      </div>
    </header>
  );
};
