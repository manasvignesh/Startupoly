import React, { useState, useEffect, useRef } from 'react';
import { Modal, PixelButton } from '../../../ui';
import { AdminRoomSnapshot } from '../../../data/rpc';
import { OFFICIAL_BUSINESSES, MAX_BUSINESSES_PER_TEAM, canAddBusiness } from '../../../domain/economy';
import { getBoardSpace } from '../../../domain/board';

export interface AddBusinessDialogProps {
  isOpen: boolean;
  onClose: () => void;
  team: AdminRoomSnapshot['teams'][0];
  allTeams: AdminRoomSnapshot['teams'];
  onSubmit: (params: { businessKey: string; applyPurchase: boolean; note?: string }) => Promise<void>;
  isTimeExpired: boolean;
}

export const AddBusinessDialog: React.FC<AddBusinessDialogProps> = ({
  isOpen,
  onClose,
  team,
  allTeams,
  onSubmit,
  isTimeExpired,
}) => {
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [applyPurchase, setApplyPurchase] = useState<boolean>(true);
  const [allowManualCatalogOverride, setAllowManualCatalogOverride] = useState<boolean>(false);
  const [note, setNote] = useState<string>('');
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  const noteRef = useRef<HTMLInputElement>(null);

  // Check what board space the team is currently standing on
  const landedSpace = getBoardSpace(team.board_position ?? 0);
  const isLandedOnBusiness = landedSpace.type === 'BUSINESS' && Boolean(landedSpace.businessKey);
  const landedBizKey = isLandedOnBusiness ? landedSpace.businessKey : null;

  // A free (manual) entry or manual catalog override bypasses the standard purchase rules
  const needsNote = isTimeExpired || !applyPurchase || (allowManualCatalogOverride && isLandedOnBusiness);

  const isCapReached = !canAddBusiness(team.businesses.length);

  // Build a map of business_key -> owner team name across all teams
  const ownerMap = new Map<string, string>();
  for (const t of allTeams) {
    for (const b of t.businesses) {
      ownerMap.set(b.business_key, t.name);
    }
  }

  useEffect(() => {
    if (isOpen) {
      // If landed on a business space, lock and pre-select that exact property by default
      if (isLandedOnBusiness && landedBizKey) {
        setSelectedKey(landedBizKey);
      } else {
        setSelectedKey(null);
      }
      setApplyPurchase(true);
      setAllowManualCatalogOverride(false);
      setNote('');
      setError(null);
      setIsSubmitting(false);
      if (isTimeExpired) {
        setTimeout(() => noteRef.current?.focus(), 50);
      }
    }
  }, [isOpen, isTimeExpired, isLandedOnBusiness, landedBizKey]);

  // When a player lands on a property, ONLY give the option to buy that landed property (unless manual override)
  const isRestrictedToLanded = isLandedOnBusiness && applyPurchase && !allowManualCatalogOverride;
  const displayedBusinesses = isRestrictedToLanded && landedBizKey
    ? OFFICIAL_BUSINESSES.filter((b) => b.key === landedBizKey)
    : OFFICIAL_BUSINESSES;

  const selectedBiz = OFFICIAL_BUSINESSES.find((b) => b.key === selectedKey);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedKey) {
      setError('Please choose a business to acquire.');
      return;
    }
    if (needsNote && !note.trim()) {
      setError(applyPurchase ? 'Note is required for manual catalog override or post-game adjustment.' : 'A note is required for a manual business entry.');
      return;
    }

    try {
      setIsSubmitting(true);
      setError(null);
      await onSubmit({
        businessKey: selectedKey,
        applyPurchase,
        note: note.trim() || undefined,
      });
      onClose();
    } catch (err: any) {
      if (err?.code === 'INSUFFICIENT_CASH' || err?.message?.includes('INSUFFICIENT_CASH')) {
        onClose();
      } else if (err?.code === 'NOT_ON_BUSINESS_SPACE') {
        setError('Server rule: Team must stand on this property’s board space to purchase it.');
      } else {
        setError(err?.message || 'Failed to add business.');
      }
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`ADD BUSINESS TO ${team.name.toUpperCase()}`}
      maxWidth="lg"
    >
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        {isCapReached && (
          <div className="bg-status-danger-bg border-2 border-brand-red p-2 text-center">
            <p className="font-mono text-xs text-brand-red font-bold">
              ⚠ Team has reached the business cap ({MAX_BUSINESSES_PER_TEAM}/{MAX_BUSINESSES_PER_TEAM}). Forced sale or removal required before adding.
            </p>
          </div>
        )}

        {/* Board Landing Indicator */}
        {isLandedOnBusiness ? (
          <div className="bg-brand-gold/20 border-2 border-brand-gold p-2.5 flex items-center justify-between gap-2 shadow-pixel-sm">
            <div className="flex items-center gap-2">
              <span className="text-base" aria-hidden="true">🎯</span>
              <div>
                <span className="font-pixel text-[11px] text-brand-navy font-bold block">
                  LANDED ON: {landedSpace.name.toUpperCase()} (SPACE #{landedSpace.index})
                </span>
                <span className="font-mono text-[10px] text-neutral-600 block">
                  {isRestrictedToLanded
                    ? 'Official Rule: Team may only acquire the property they landed on.'
                    : 'Manual override active.'}
                </span>
              </div>
            </div>

            <label className="flex items-center gap-1.5 cursor-pointer text-right">
              <input
                type="checkbox"
                checked={allowManualCatalogOverride}
                onChange={(e) => {
                  setAllowManualCatalogOverride(e.target.checked);
                  if (!e.target.checked && landedBizKey) {
                    setSelectedKey(landedBizKey);
                  }
                }}
                className="w-3.5 h-3.5 accent-brand-navy cursor-pointer"
              />
              <span className="font-pixel text-[9px] text-brand-navy">
                OVERRIDE
              </span>
            </label>
          </div>
        ) : (
          <div className="bg-sky-50 border-2 border-brand-navy p-2.5 flex items-center justify-between gap-2 shadow-pixel-sm">
            <div className="flex items-center gap-2">
              <span className="text-base" aria-hidden="true">📍</span>
              <div>
                <span className="font-pixel text-[11px] text-brand-navy font-bold block">
                  POSITION: {landedSpace.name.toUpperCase()} (SPACE #{landedSpace.index})
                </span>
                <span className="font-mono text-[10px] text-neutral-600 block">
                  Not a business tile. Choose which business space {team.name} landed on:
                </span>
              </div>
            </div>

            <label className="flex items-center gap-1.5 cursor-pointer text-right">
              <input
                type="checkbox"
                checked={allowManualCatalogOverride}
                onChange={(e) => setAllowManualCatalogOverride(e.target.checked)}
                className="w-3.5 h-3.5 accent-brand-navy cursor-pointer"
              />
              <span className="font-pixel text-[9px] text-brand-navy">
                OVERRIDE
              </span>
            </label>
          </div>
        )}

        {/* Catalog Business Picker */}
        <div className="flex flex-col gap-2">
          <label className="font-pixel text-[11px] uppercase tracking-wider text-brand-navy">
            {isRestrictedToLanded ? 'Landed Property Available to Buy' : 'Select Catalog Business'} ({team.businesses.length}/{MAX_BUSINESSES_PER_TEAM} Owned)
          </label>

          <div className={`grid ${displayedBusinesses.length === 1 ? 'grid-cols-1' : 'grid-cols-1 sm:grid-cols-2'} gap-2 max-h-60 overflow-y-auto pr-1`}>
            {displayedBusinesses.map((b) => {
              const ownerName = ownerMap.get(b.key);
              const isOwned = Boolean(ownerName);
              const isSelected = selectedKey === b.key;
              const disabled = isCapReached || isOwned;

              return (
                <button
                  type="button"
                  key={b.key}
                  disabled={disabled}
                  onClick={() => {
                    setSelectedKey(b.key);
                    setError(null);
                  }}
                  className={`
                    p-3 text-left border-2 transition-all flex flex-col justify-between gap-1
                    ${
                      disabled
                        ? 'bg-neutral-100 border-neutral-300 opacity-60 cursor-not-allowed'
                        : isSelected
                        ? 'bg-brand-gold border-brand-navy shadow-pixel-sm ring-2 ring-brand-navy'
                        : 'bg-brand-white border-brand-navy hover:bg-brand-cream cursor-pointer'
                    }
                  `}
                >
                  <div className="flex items-center justify-between gap-1">
                    <span className="font-pixel text-xs text-brand-navy truncate">
                      {b.name}
                    </span>
                    {isSelected && (
                      <span className="font-pixel text-xs text-brand-navy font-bold">✓ SELECTED</span>
                    )}
                  </div>

                  <div className="flex items-center justify-between font-mono text-[11px]">
                    <span className="text-neutral-700 font-bold">Cost: ₹{b.cost.toLocaleString('en-IN')}</span>
                    {isLandedOnBusiness && b.key === landedBizKey && (
                      <span className="font-pixel text-[9px] bg-brand-green text-white px-1.5 py-0.5 rounded">
                        LANDED
                      </span>
                    )}
                  </div>

                  {isOwned && (
                    <span className="font-mono text-[10px] text-brand-red font-bold truncate">
                      Already owned by {ownerName}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </div>

        {/* Apply Purchase Financial Side-Effect Checkbox */}
        {selectedBiz && (
          <div className="bg-brand-cream border-2 border-brand-navy p-3 flex flex-col gap-2">
            <label className="flex items-center gap-2 cursor-pointer select-none">
              <input
                type="checkbox"
                checked={applyPurchase}
                onChange={(e) => setApplyPurchase(e.target.checked)}
                className="w-4 h-4 accent-brand-green cursor-pointer"
              />
              <span className="font-sans text-xs font-bold text-brand-navy">
                Apply purchase (−₹{selectedBiz.cost.toLocaleString('en-IN')})
              </span>
            </label>
            <p className="font-mono text-[11px] text-neutral-500 pl-6">
              {applyPurchase
                ? `Will deduct ₹${selectedBiz.cost.toLocaleString('en-IN')} from ${team.name}'s cash.`
                : 'Manual entry only: does not modify team cash.'}
            </p>
          </div>
        )}

        {/* Note requirement for manual override or post-match adjustments */}
        {needsNote && (
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[10px] uppercase text-brand-red font-bold">
              ⚠ NOTE REQUIRED ({isTimeExpired ? 'GAME OVER ADJUSTMENT' : allowManualCatalogOverride ? 'CATALOG OVERRIDE' : 'MANUAL ENTRY'})
            </label>
            <input
              ref={noteRef}
              type="text"
              required
              placeholder="e.g., Physical auction purchase confirmed with table ref"
              value={note}
              onChange={(e) => setNote(e.target.value)}
              className="
                w-full px-2.5 py-1.5 font-sans text-xs text-brand-navy bg-brand-white border-2 border-brand-navy
                focus:outline-none focus:ring-2 focus:ring-brand-red
              "
            />
          </div>
        )}

        {error && (
          <span className="font-mono text-xs text-brand-red font-bold">
            ⚠ {error}
          </span>
        )}

        {/* Modal Actions */}
        <div className="flex items-center justify-end gap-2 pt-2 border-t-2 border-brand-navy">

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
            disabled={isSubmitting}
            className="
              font-pixel text-xs uppercase px-3 py-1.5 bg-brand-white text-brand-navy
              border-2 border-brand-navy shadow-pixel-sm hover:bg-neutral-200
              cursor-pointer active:translate-y-0.5 disabled:opacity-50
            "
          >
            CANCEL
          </button>
          <PixelButton
            type="submit"
            variant="primary"
            size="md"
            disabled={!selectedKey || isCapReached || isSubmitting || (needsNote && !note.trim())}
            isLoading={isSubmitting}
          >
            CONFIRM ACQUISITION
          </PixelButton>
          </div>
        </div>
      </form>
    </Modal>
  );
};
