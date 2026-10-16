import React, { useState, useEffect } from 'react';
import { Modal, PixelButton } from '../../../../ui';
import { PreviewTable } from './PreviewTable';
import { computeStart, TeamState } from '../../../../domain/quickActions';
import { safeRandomUUID } from '../../../../lib/uuid';

export interface StartLapDialogProps {
  isOpen: boolean;
  onClose: () => void;
  teams: TeamState[];
  defaultTeamId?: string;
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
}

export const StartLapDialog: React.FC<StartLapDialogProps> = ({
  isOpen,
  onClose,
  teams,
  defaultTeamId,
  isTimeExpired,
  onSubmit,
}) => {
  const [teamId, setTeamId] = useState<string>(defaultTeamId || teams[0]?.id || '');
  const [customCash, setCustomCash] = useState<number | undefined>(undefined);
  const [customCv, setCustomCv] = useState<number | undefined>(undefined);
  const [note, setNote] = useState<string>('');
  const [requestId, setRequestId] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      setTeamId(defaultTeamId || teams[0]?.id || '');
      setCustomCash(undefined);
      setCustomCv(undefined);
      setNote('');
      setRequestId(safeRandomUUID());
      setError(null);
      setIsSubmitting(false);
    }
  }, [isOpen, defaultTeamId, teams]);

  const team = teams.find((t) => t.id === teamId);
  const preview = team ? computeStart(team, customCash, customCv) : null;

  const handleAdjust = (_targetId: string, cashDelta: number, cvDelta: number) => {
    setCustomCash(cashDelta);
    setCustomCv(cvDelta);
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
        label: 'START_LAP',
        note: note.trim() || undefined,
        requestId,
      });
      onClose();
    } catch (err: any) {
      setError(err?.message || 'Failed to award START lap.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="RECORD START LAP (PASS OR LAND)" maxWidth="md">
      <div className="flex flex-col gap-4">
        {/* Team Selector */}
        <div className="flex flex-col gap-1">
          <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
            Team Crossing or Landing on START
          </label>
          <select
            value={teamId}
            onChange={(e) => {
              setTeamId(e.target.value);
              setCustomCash(undefined);
              setCustomCv(undefined);
            }}
            className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#22B14C]"
          >
            {teams.map((t) => (
              <option key={t.id} value={t.id}>
                #{t.slot}: {t.name} ({t.businesses.length}/3 businesses)
              </option>
            ))}
          </select>
        </div>

        {/* Preview Table */}
        {preview && (
          <PreviewTable
            preview={preview}
            isTimeExpired={isTimeExpired}
            note={note}
            onNoteChange={setNote}
            onAdjustAmount={handleAdjust}
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
            disabled={!preview || isSubmitting || (isTimeExpired && !note.trim())}
            isLoading={isSubmitting}
            onClick={handleConfirm}
          >
            CONFIRM START LAP
          </PixelButton>
        </div>
      </div>
    </Modal>
  );
};
