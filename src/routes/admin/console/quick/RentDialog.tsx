import React, { useState, useEffect } from 'react';
import { Modal, PixelButton } from '../../../../ui';
import { PreviewTable } from './PreviewTable';
import { computeRent, TeamState } from '../../../../domain/quickActions';
import { safeRandomUUID } from '../../../../lib/uuid';

export interface RentDialogProps {
  isOpen: boolean;
  onClose: () => void;
  teams: TeamState[];
  defaultPayerId?: string;
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

export const RentDialog: React.FC<RentDialogProps> = ({
  isOpen,
  onClose,
  teams,
  defaultPayerId,
  isTimeExpired,
  onSubmit,
  onDoForcedSale,
  onDeclareBankrupt,
}) => {
  const [payerId, setPayerId] = useState<string>(defaultPayerId || teams[0]?.id || '');
  const [businessKey, setBusinessKey] = useState<string>('');
  const [customRent, setCustomRent] = useState<number | undefined>(undefined);
  const [customCv, setCustomCv] = useState<number | undefined>(undefined);
  const [note, setNote] = useState<string>('');
  const [requestId, setRequestId] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  // All businesses owned across the room by any team other than current payer
  const eligibleBusinesses = teams
    .filter((t) => t.id !== payerId)
    .flatMap((t) =>
      t.businesses.map((b) => ({
        ...b,
        ownerId: t.id,
        ownerName: t.name,
        ownerColor: t.color,
      }))
    );

  useEffect(() => {
    if (isOpen) {
      setPayerId(defaultPayerId || teams[0]?.id || '');
      setCustomRent(undefined);
      setCustomCv(undefined);
      setNote('');
      setRequestId(safeRandomUUID());
      setError(null);
      setIsSubmitting(false);
    }
  }, [isOpen, defaultPayerId, teams]);

  useEffect(() => {
    if (eligibleBusinesses.length > 0 && !eligibleBusinesses.some((b) => b.business_key === businessKey)) {
      setBusinessKey(eligibleBusinesses[0].business_key);
    }
  }, [payerId, eligibleBusinesses, businessKey]);

  const payer = teams.find((t) => t.id === payerId);
  const selectedBizInfo = eligibleBusinesses.find((b) => b.business_key === businessKey);
  const owner = selectedBizInfo ? teams.find((t) => t.id === selectedBizInfo.ownerId) : null;

  const preview =
    payer && owner && businessKey
      ? computeRent(payer, businessKey, owner, customRent, customCv)
      : null;

  const handleAdjust = (teamId: string, cashDelta: number, cvDelta: number) => {
    if (payer && teamId === payer.id) {
      setCustomRent(Math.abs(cashDelta));
    } else if (owner && teamId === owner.id) {
      setCustomRent(cashDelta);
      setCustomCv(cvDelta);
    }
  };

  const handleConfirm = async () => {
    if (!preview || preview.hasShortfall) return;
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
        label: 'RENT',
        note: note.trim() || undefined,
        requestId,
      });
      onClose();
    } catch (err: any) {
      setError(err?.message || 'Failed to submit rent transaction.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="RECORD RENT PAYMENT" maxWidth="lg">
      <div className="flex flex-col gap-4">
        {/* Payer and Target Business Selection */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {/* Payer select */}
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
              Payer Team (Landed)
            </label>
            <select
              value={payerId}
              onChange={(e) => {
                setPayerId(e.target.value);
                setCustomRent(undefined);
                setCustomCv(undefined);
              }}
              className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#FFCC00]"
            >
              {teams.map((t) => (
                <option key={t.id} value={t.id}>
                  #{t.slot}: {t.name} (₹{t.cash.toLocaleString('en-IN')})
                </option>
              ))}
            </select>
          </div>

          {/* Business Select */}
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[11px] uppercase tracking-wider text-[#102040]">
              Landed Property (Owned by others)
            </label>
            {eligibleBusinesses.length === 0 ? (
              <div className="p-2 bg-[#FAF8F5] border-2 border-dashed border-[#CBD5E1] text-xs font-mono text-[#64748B]">
                No businesses owned by other teams.
              </div>
            ) : (
              <select
                value={businessKey}
                onChange={(e) => {
                  setBusinessKey(e.target.value);
                  setCustomRent(undefined);
                  setCustomCv(undefined);
                }}
                className="p-2 border-2 border-[#102040] bg-white font-sans text-xs font-bold text-[#102040] focus:outline-none focus:ring-2 focus:ring-[#FFCC00]"
              >
                {eligibleBusinesses.map((b) => (
                  <option key={`${b.ownerId}-${b.business_key}`} value={b.business_key}>
                    {b.name} (L{b.level}) • Owned by {b.ownerName}
                  </option>
                ))}
              </select>
            )}
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
            CONFIRM RENT
          </PixelButton>
        </div>
      </div>
    </Modal>
  );
};
