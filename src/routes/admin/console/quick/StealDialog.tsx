import React, { useState, useEffect } from 'react';
import { Modal, PixelButton } from '../../../../ui';
import { PreviewTable } from './PreviewTable';
import { computeSteal, TeamState } from '../../../../domain/quickActions';
import { safeRandomUUID } from '../../../../lib/uuid';

export interface StealDialogProps {
  isOpen: boolean;
  onClose: () => void;
  teams: TeamState[];
  defaultThiefId?: string;
  isTimeExpired: boolean;
  onSubmit: (params: {
    changes: Array<{
      team_id: string;
      cash_delta: number;
      cv_delta: number;
      expected_version: number;
    }>;
    label: string;
    note?: string;
    requestId: string;
  }) => Promise<void>;
  onDoForcedSale?: (teamId: string, shortfall: number) => void;
  onDeclareBankrupt?: (teamId: string) => void;
}

export const StealDialog: React.FC<StealDialogProps> = ({
  isOpen,
  onClose,
  teams,
  defaultThiefId,
  isTimeExpired,
  onSubmit,
  onDoForcedSale,
  onDeclareBankrupt,
}) => {
  const [thiefId, setThiefId] = useState<string>(defaultThiefId || teams[0]?.id || '');
  const [victimId, setVictimId] = useState<string>('');
  const [customAmount, setCustomAmount] = useState<number | undefined>(undefined);
  const [note, setNote] = useState<string>('');
  const [requestId, setRequestId] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  const eligibleVictims = teams.filter((t) => t.id !== thiefId);

  useEffect(() => {
    if (isOpen) {
      const initialThief = defaultThiefId || teams[0]?.id || '';
      setThiefId(initialThief);
      const firstVictim = teams.find((t) => t.id !== initialThief)?.id || '';
      setVictimId(firstVictim);
      setCustomAmount(undefined);
      setNote('');
      setRequestId(safeRandomUUID());
      setError(null);
      setIsSubmitting(false);
    }
  }, [isOpen, defaultThiefId, teams]);

  useEffect(() => {
    if (thiefId === victimId || !eligibleVictims.some((t) => t.id === victimId)) {
      setVictimId(eligibleVictims[0]?.id || '');
      setCustomAmount(undefined);
    }
  }, [thiefId, victimId, eligibleVictims]);

  const thief = teams.find((t) => t.id === thiefId);
  const victim = teams.find((t) => t.id === victimId);

  const preview = thief && victim ? computeSteal(thief, victim, customAmount) : null;

  const handleAdjust = (_targetId: string, cashDelta: number) => {
    setCustomAmount(Math.abs(cashDelta));
  };

  const handleConfirm = async () => {
    if (!preview) return;
    if (isTimeExpired && !note.trim()) {
      setError('Note is required for post-game adjustments.');
      return;
    }

    try {
      setIsSubmitting(true);
      setError(null);
      const changes = preview.changes.map((ch) => ({
        team_id: ch.teamId,
        cash_delta: ch.cashDelta,
        cv_delta: ch.cvDelta,
        expected_version: ch.expectedVersion,
      }));

      await onSubmit({
        changes,
        label: 'STEAL_TALENT',
        note: note.trim() || undefined,
        requestId,
      });
      onClose();
    } catch (err: any) {
      setError(err?.message || 'Failed to execute talent steal.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="STEAL TALENT (UP TO ₹100)" maxWidth="md">
      <div className="flex flex-col gap-4">
        {/* Thief & Victim Pickers */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
              Thief Team (Receives Cash)
            </label>
            <select
              value={thiefId}
              onChange={(e) => {
                setThiefId(e.target.value);
                setCustomAmount(undefined);
              }}
              className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#FFCC00]"
            >
              {teams.map((t) => (
                <option key={t.id} value={t.id}>
                  #{t.slot}: {t.name}
                </option>
              ))}
            </select>
          </div>

          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
              Victim Team (Pays Cash)
            </label>
            <select
              value={victimId}
              onChange={(e) => {
                setVictimId(e.target.value);
                setCustomAmount(undefined);
              }}
              className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#FFCC00]"
            >
              {eligibleVictims.map((t) => (
                <option key={t.id} value={t.id}>
                  #{t.slot}: {t.name} (has ₹{t.cash.toLocaleString('en-IN')})
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* Preview Table */}
        {preview && (
          <PreviewTable
            preview={preview}
            isTimeExpired={isTimeExpired}
            note={note}
            onNoteChange={setNote}
            onAdjustAmount={handleAdjust}
            onDoForcedSale={onDoForcedSale}
            onDeclareBankrupt={onDeclareBankrupt}
          />
        )}

        {error && (
          <span className="font-mono text-xs text-[#D32F2F] font-bold">
            ⚠ {error}
          </span>
        )}

        {/* Modal Actions */}
        <div className="flex items-center justify-end gap-2 pt-2 border-t-2 border-[#102040]">
          <button
            type="button"
            onClick={onClose}
            disabled={isSubmitting}
            className="font-pixel text-xs uppercase px-3 py-1.5 bg-white text-[#102040] border-2 border-[#102040] shadow-[1px_1px_0px_#102040] hover:bg-[#EAE5D9] cursor-pointer"
          >
            CANCEL (Esc)
          </button>
          <PixelButton
            variant="primary"
            size="md"
            disabled={!preview || preview.hasShortfall || isSubmitting || (isTimeExpired && !note.trim())}
            isLoading={isSubmitting}
            onClick={handleConfirm}
          >
            CONFIRM STEAL
          </PixelButton>
        </div>
      </div>
    </Modal>
  );
};
