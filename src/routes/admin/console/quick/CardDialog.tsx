import React, { useState, useEffect } from 'react';
import { Modal, PixelButton } from '../../../../ui';
import { PreviewTable } from './PreviewTable';
import { computeBonus, computeCrisis, TeamState } from '../../../../domain/quickActions';
import { safeRandomUUID } from '../../../../lib/uuid';

export interface CardDialogProps {
  isOpen: boolean;
  onClose: () => void;
  teams: TeamState[];
  defaultTeamId?: string;
  defaultMode?: 'BONUS' | 'CRISIS';
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

const BONUS_CARD_DESCRIPTIONS: Record<number, string> = {
  1: 'Bonus #1: +₹300 Cash',
  2: 'Bonus #2: +300 Company Value',
  3: 'Bonus #3: +₹200 Cash & +200 Company Value',
  4: 'Bonus #4: Cash equal to most expensive business owned',
  5: 'Bonus #5: +₹100 Cash per business owned',
  6: 'Bonus #6 (Lucky Break): Roll a die, get ₹100 × roll',
};

const CRISIS_CARD_DESCRIPTIONS: Record<number, string> = {
  1: 'Crisis #1: −₹300 Cash',
  2: 'Crisis #2: −300 Company Value',
  3: 'Crisis #3: −₹200 Cash & −200 Company Value',
  4: 'Crisis #4: −₹100 Cash per business owned',
  5: 'Crisis #5: −₹100 Cash & −200 Company Value',
  6: 'Crisis #6: −₹500 Cash',
};

export const CardDialog: React.FC<CardDialogProps> = ({
  isOpen,
  onClose,
  teams,
  defaultTeamId,
  defaultMode = 'BONUS',
  isTimeExpired,
  onSubmit,
  onDoForcedSale,
  onDeclareBankrupt,
}) => {
  const [teamId, setTeamId] = useState<string>(defaultTeamId || teams[0]?.id || '');
  const [mode, setMode] = useState<'BONUS' | 'CRISIS'>(defaultMode);
  const [cardNo, setCardNo] = useState<number>(1);
  const [rewardRoll, setRewardRoll] = useState<number>(1);
  const [customCash, setCustomCash] = useState<number | undefined>(undefined);
  const [customCv, setCustomCv] = useState<number | undefined>(undefined);
  const [note, setNote] = useState<string>('');
  const [requestId, setRequestId] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      setTeamId(defaultTeamId || teams[0]?.id || '');
      setMode(defaultMode);
      setCardNo(1);
      setRewardRoll(1);
      setCustomCash(undefined);
      setCustomCv(undefined);
      setNote('');
      setRequestId(safeRandomUUID());
      setError(null);
      setIsSubmitting(false);
    }
  }, [isOpen, defaultTeamId, defaultMode, teams]);

  const team = teams.find((t) => t.id === teamId);

  const preview = team
    ? mode === 'BONUS'
      ? computeBonus(team, cardNo, rewardRoll, customCash, customCv)
      : computeCrisis(team, cardNo, customCash, customCv)
    : null;

  const handleAdjust = (_targetId: string, cashDelta: number, cvDelta: number) => {
    setCustomCash(cashDelta);
    setCustomCv(cvDelta);
  };

  const handleConfirm = async () => {
    if (!preview) return;
    if (preview.hasShortfall) {
      setError('Cannot execute: team has insufficient cash. Complete a forced sale or declare bankruptcy.');
      return;
    }
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
        label: preview.label,
        note: note.trim() || undefined,
        requestId,
      });
      onClose();
    } catch (err: any) {
      setError(err?.message || `Failed to apply ${mode.toLowerCase()} card.`);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`RECORD ${mode} CARD`}
      maxWidth="md"
    >
      <div className="flex flex-col gap-4">
        {/* Mode Toggle: BONUS vs CRISIS */}
        <div className="flex border-2 border-[#102040] shadow-[2px_2px_0px_#102040]">
          <button
            type="button"
            onClick={() => {
              setMode('BONUS');
              setCustomCash(undefined);
              setCustomCv(undefined);
            }}
            className={`flex-1 py-2 font-pixel text-xs uppercase cursor-pointer transition-colors ${
              mode === 'BONUS'
                ? 'bg-[#22B14C] text-white font-bold'
                : 'bg-white text-[#102040] hover:bg-[#FAF8F5]'
            }`}
          >
            ★ BONUS CARD
          </button>
          <button
            type="button"
            onClick={() => {
              setMode('CRISIS');
              setCustomCash(undefined);
              setCustomCv(undefined);
            }}
            className={`flex-1 py-2 font-pixel text-xs uppercase cursor-pointer border-l-2 border-[#102040] transition-colors ${
              mode === 'CRISIS'
                ? 'bg-[#D32F2F] text-white font-bold'
                : 'bg-white text-[#102040] hover:bg-[#FAF8F5]'
            }`}
          >
            ⚠ CRISIS CARD
          </button>
        </div>

        {/* Team Selector */}
        <div className="flex flex-col gap-1">
          <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
            Target Team
          </label>
          <select
            value={teamId}
            onChange={(e) => {
              setTeamId(e.target.value);
              setCustomCash(undefined);
              setCustomCv(undefined);
            }}
            className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#5C94FC]"
          >
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                #{t.slot}: {t.name} (Cash: ₹{t.cash.toLocaleString('en-IN')}, {t.businesses.length} businesses)
              </option>
            ))}
          </select>
        </div>

        {/* Card Number Selector (1 to 6) */}
        <div className="flex flex-col gap-1">
          <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
            Card Number (1–6)
          </label>
          <div className="grid grid-cols-6 gap-1">
            {[1, 2, 3, 4, 5, 6].map((num) => (
              <button
                key={num}
                type="button"
                onClick={() => {
                  setCardNo(num);
                  setCustomCash(undefined);
                  setCustomCv(undefined);
                }}
                className={`py-2 border-2 border-[#102040] font-pixel text-xs cursor-pointer shadow-[1px_1px_0px_#102040] ${
                  cardNo === num
                    ? 'bg-[#FFCC00] text-[#102040] font-bold ring-2 ring-[#102040]'
                    : 'bg-white text-[#102040] hover:bg-[#FAF8F5]'
                }`}
              >
                #{num}
              </button>
            ))}
          </div>
          <span className="font-sans text-xs text-[#64748B] italic mt-0.5">
            {mode === 'BONUS'
              ? BONUS_CARD_DESCRIPTIONS[cardNo]
              : CRISIS_CARD_DESCRIPTIONS[cardNo]}
          </span>
        </div>

        {/* Lucky Break Die Roll selector for Bonus #6 */}
        {mode === 'BONUS' && cardNo === 6 && (
          <div className="bg-[#FFFBEB] border-2 border-[#102040] p-2.5 flex items-center justify-between gap-2 shadow-[1px_1px_0px_#102040]">
            <span className="font-pixel text-[11px] uppercase text-[#92400E] font-bold">
              Physical Die Roll (1–6):
            </span>
            <div className="flex items-center gap-1">
              {[1, 2, 3, 4, 5, 6].map((roll) => (
                <button
                  key={roll}
                  type="button"
                  onClick={() => {
                    setRewardRoll(roll);
                    setCustomCash(undefined);
                    setCustomCv(undefined);
                  }}
                  className={`w-7 h-7 border border-[#102040] font-pixel text-xs cursor-pointer ${
                    rewardRoll === roll
                      ? 'bg-[#22B14C] text-white font-bold'
                      : 'bg-white text-[#102040] hover:bg-[#EAE5D9]'
                  }`}
                >
                  {roll}
                </button>
              ))}
            </div>
          </div>
        )}

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
            variant={mode === 'BONUS' ? 'primary' : 'danger'}
            size="md"
            disabled={!preview || preview.hasShortfall || isSubmitting || (isTimeExpired && !note.trim())}
            isLoading={isSubmitting}
            onClick={handleConfirm}
          >
            APPLY {mode} #{cardNo}
          </PixelButton>
        </div>
      </div>
    </Modal>
  );
};
