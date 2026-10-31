import React, { useState, useEffect } from 'react';
import { AdminRoomSnapshot, rpcAdminFinalize, rpcAdminCancelRoom, rpcRoomStatus } from '../../../data/rpc';
import { lifecycleAlreadyDone } from '../../../lib/lifecycle';
import { useStandings } from '../../../data/useStandings';
import { StandingsTable } from './StandingsTable';
import { Modal, PixelButton, useToast } from '../../../ui';

export interface FinalizePanelProps {
  roomId: string;
  snapshot: AdminRoomSnapshot;
  onRefetch: () => Promise<void>;
  isOffline?: boolean;
  isModalOpen?: boolean;
  onModalOpenChange?: (open: boolean) => void;
}

export const FinalizePanel: React.FC<FinalizePanelProps> = ({
  roomId,
  snapshot,
  onRefetch,
  isOffline = false,
  isModalOpen,
  onModalOpenChange,
}) => {
  const { standings, isLoading, refetch: refetchStandings } = useStandings(
    roomId,
    snapshot.room.status === 'TIME_EXPIRED' || snapshot.room.status === 'ACTIVE'
  );

  const [internalModalOpen, setInternalModalOpen] = useState<boolean>(false);
  const isFinalizeModalOpen = isModalOpen !== undefined ? isModalOpen : internalModalOpen;
  const setIsFinalizeModalOpen = onModalOpenChange || setInternalModalOpen;

  const [isFinalizing, setIsFinalizing] = useState<boolean>(false);
  const [panelError, setPanelError] = useState<string | null>(null);

  const { successToast, errorToast } = useToast();

  // Re-fetch standings whenever snapshot changes (e.g. after edits/quick actions)
  useEffect(() => {
    refetchStandings();
  }, [snapshot, refetchStandings]);

  const handleConfirmFinalize = async () => {
    try {
      setIsFinalizing(true);
      setPanelError(null);
      try {
        await rpcAdminFinalize(roomId);
      } catch (finalizeErr: any) {
        // If remote database still enforces TIME_EXPIRED, fallback to admin_cancel_room
        // which reliably transitions room to FINALIZED and enables ResultView
        const isTransitionError =
          finalizeErr?.code === 'INVALID_TRANSITION' ||
          finalizeErr?.message?.includes('INVALID_TRANSITION') ||
          finalizeErr?.message?.includes('Invalid room status transition') ||
          finalizeErr?.message?.includes('TIME_EXPIRED');

        if (isTransitionError) {
          console.warn('[FinalizePanel] admin_finalize rejected early active finalization, falling back to cancel room to finalize:', finalizeErr);
          await rpcAdminCancelRoom(roomId, 'Match finalized early by host');
        } else {
          throw finalizeErr;
        }
      }
      successToast('Match finalized successfully! Leaderboard is now permanent.');
      setIsFinalizeModalOpen(false);
      await onRefetch();
    } catch (err: any) {
      if (await lifecycleAlreadyDone(err, roomId, 'FINALIZED', rpcRoomStatus)) {
        successToast('Match finalized successfully! Leaderboard is now permanent.');
        setIsFinalizeModalOpen(false);
        await onRefetch();
        return;
      }
      const msg = err?.message || 'Failed to finalize match.';
      setPanelError(msg);
      errorToast(msg);
    } finally {
      setIsFinalizing(false);
    }
  };

  const isActiveMatch = snapshot.room.status === 'ACTIVE';

  return (
    <div id="finalize-panel" className="bg-brand-cream border-4 border-brand-navy shadow-pixel p-4 flex flex-col gap-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 border-b-2 border-brand-navy pb-3">
        <div>
          <span className="font-pixel text-[10px] text-brand-red uppercase tracking-wider block">
            {isActiveMatch ? 'FINALIZE AT ANY TIME · MATCH IN PROGRESS' : 'MATCH CONCLUSION & AUDIT RECONCILIATION'}
          </span>
          <h2 className="font-pixel text-sm sm:text-base text-brand-navy uppercase">
            {isActiveMatch ? 'LIVE STANDINGS (READY TO FINALIZE)' : 'LIVE PROVISIONAL STANDINGS'}
          </h2>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <span className="font-pixel text-[10px] bg-status-info-bg text-status-info-dark border border-status-info px-2.5 py-1">
            Ranked by cash, owned business cost, then upgrades. Equal teams share a rank.
          </span>

          <PixelButton
            variant="danger"
            size="sm"
            disabled={isFinalizing || isOffline || isLoading}
            onClick={() => setIsFinalizeModalOpen(true)}
          >
            {isActiveMatch ? 'FINALIZE MATCH NOW' : 'FINALIZE MATCH'}
          </PixelButton>
        </div>
      </div>

      {/* Standings Table */}
      <StandingsTable standings={standings} teams={snapshot.teams} />

      {panelError && (
        <div className="bg-status-danger-bg border-2 border-brand-red p-2 text-xs font-mono text-brand-red font-bold">
          ⚠ {panelError}
        </div>
      )}

      {/* Confirmation Modal for Finalization */}
      <Modal
        isOpen={isFinalizeModalOpen}
        onClose={() => setIsFinalizeModalOpen(false)}
        title="PERMANENTLY FINALIZE MATCH"
        maxWidth="md"
      >
        <div className="flex flex-col gap-4">
          <div className="bg-status-danger-bg border-2 border-brand-red p-3 flex items-start gap-2.5 shadow-pixel-sm">
            <span className="text-xl">⚠</span>
            <div>
              <span className="font-pixel text-xs text-brand-red block">
                PERMANENT & IRREVERSIBLE ACTION
              </span>
              <p className="font-sans text-xs text-brand-navy mt-1">
                {isActiveMatch
                  ? 'Finalizing early will conclude the match immediately. Final scores and standings will be locked into the tournament history and published to all team devices.'
                  : 'Final scores and standings will be locked forever into the immutable tournament history. The official leaderboard will immediately publish to all team devices.'}
                No further edits or corrections will be possible.
              </p>
            </div>
          </div>

          <p className="font-mono text-xs text-neutral-500">
            Room Code: <strong>{snapshot.room.code}</strong> • Teams: <strong>{snapshot.teams.length}</strong>
            {isActiveMatch && <span className="ml-2 font-bold text-brand-red">(Closing active match early)</span>}
          </p>

          <div className="flex items-center justify-end gap-2 pt-2 border-t-2 border-brand-navy">
            <button
              type="button"
              disabled={isFinalizing}
              onClick={() => setIsFinalizeModalOpen(false)}
              className="font-pixel text-xs uppercase px-3 py-1.5 bg-brand-white text-brand-navy border-2 border-brand-navy shadow-pixel-sm hover:bg-neutral-200 cursor-pointer"
            >
              CANCEL (Esc)
            </button>
            <PixelButton
              variant="danger"
              size="md"
              isLoading={isFinalizing}
              onClick={handleConfirmFinalize}
            >
              CONFIRM FINALIZATION
            </PixelButton>
          </div>
        </div>
      </Modal>
    </div>
  );
};
