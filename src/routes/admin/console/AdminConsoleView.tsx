import React, { useState, useEffect } from 'react';
import { ConsoleTopBar } from './ConsoleTopBar';
import { TeamGrid } from './TeamGrid';
import { TeamEditor } from './TeamEditor';
import { ActivityLog } from './ActivityLog';
import { AddBusinessDialog } from './AddBusinessDialog';
import { UpgradeDialog } from './UpgradeDialog';
import { EditBusinessDialog } from './EditBusinessDialog';
import { RemoveBusinessDialog } from './RemoveBusinessDialog';
import { BankruptDialog } from './BankruptDialog';
import { ConflictDialog } from './ConflictDialog';
import { useToast, Modal, PixelButton } from '../../../ui';
import { ConnectionStatus } from '../../../ui/ConnectionPill';
import {
  AdminRoomSnapshot,
  rpcAdminSetTeamValues,
  rpcAdminAdjust,
  rpcAdminAddBusiness,
  rpcAdminSetBusinessLevel,
  rpcAdminRemoveBusiness,
  rpcAdminSetBankrupt,
  rpcAdminAbortGame,
} from '../../../data/rpc';
import {
  QuickActionsBar,
  RentDialog,
  StartLapDialog,
  StealDialog,
  CardDialog,
  LoseFeatureDialog,
  ForcedSaleDialog,
} from './quick';
import { FinalizePanel } from './FinalizePanel';
import { ResultView } from './ResultView';
import { safeRandomUUID } from '../../../lib/uuid';

export interface AdminConsoleViewProps {
  snapshot: AdminRoomSnapshot;
  onRefetch: () => Promise<void>;
  connection: ConnectionStatus;
  lastUpdated: string;
  isStale?: boolean;
  staleAgeSeconds?: number;
}

export const AdminConsoleView: React.FC<AdminConsoleViewProps> = ({
  snapshot,
  onRefetch,
  connection,
  lastUpdated,
  isStale = false,
  staleAgeSeconds = 0,
}) => {
  const [selectedTeamId, setSelectedTeamId] = useState<string>(
    snapshot.teams[0]?.id || ''
  );
  const [isRefetching, setIsRefetching] = useState<boolean>(false);
  const [flashes, setFlashes] = useState<Record<string, 'up' | 'down' | null>>({});
  const [lastFailedAction, setLastFailedAction] = useState<{
    label: string;
    retry: () => void;
    error: string;
  } | null>(null);

  // Modals state
  const [isAddOpen, setIsAddOpen] = useState<boolean>(false);
  const [upgradeBizKey, setUpgradeBizKey] = useState<string | null>(null);
  const [editBizKey, setEditBizKey] = useState<string | null>(null);
  const [removeBizKey, setRemoveBizKey] = useState<string | null>(null);
  const [bankruptMode, setBankruptMode] = useState<'declare' | 'undo' | null>(null);

  // Quick actions modal state
  const [isRentOpen, setIsRentOpen] = useState<boolean>(false);
  const [isStartLapOpen, setIsStartLapOpen] = useState<boolean>(false);
  const [isStealOpen, setIsStealOpen] = useState<boolean>(false);
  const [isCardOpen, setIsCardOpen] = useState<boolean>(false);
  const [cardMode, setCardMode] = useState<'BONUS' | 'CRISIS'>('BONUS');
  const [isLoseFeatureOpen, setIsLoseFeatureOpen] = useState<boolean>(false);
  const [isForcedSaleOpen, setIsForcedSaleOpen] = useState<boolean>(false);
  const [forcedSaleTeamId, setForcedSaleTeamId] = useState<string>('');
  const [forcedSaleShortfall, setForcedSaleShortfall] = useState<number | undefined>(undefined);

  // Conflict & Insufficient Cash states
  const [conflictDetails, setConflictDetails] = useState<{
    expectedVersion?: number;
    currentVersion?: number;
    cash?: number;
    cv?: number;
  } | null>(null);
  const [insufficientCashShortfall, setInsufficientCashShortfall] = useState<number | null>(null);

  const { successToast, errorToast } = useToast();

  const isTimeExpired = snapshot.room.status === 'TIME_EXPIRED';
  const isActive = snapshot.room.status === 'ACTIVE';
  const isOffline = connection === 'OFFLINE';
  const isStaleData = isStale || staleAgeSeconds > 30;
  const isEditDisabled = isOffline || isStaleData;

  // Abort Game state
  const [showAbortModal, setShowAbortModal] = useState<boolean>(false);
  const [isAborting, setIsAborting] = useState<boolean>(false);
  const [abortNote, setAbortNote] = useState<string>('');
  const [abortError, setAbortError] = useState<string | null>(null);

  const handleOpenAbort = () => {
    setAbortNote('');
    setAbortError(null);
    setShowAbortModal(true);
  };

  // Ensure selectedTeamId is always valid even if teams change
  useEffect(() => {
    if (!snapshot.teams.some((t) => t.id === selectedTeamId)) {
      if (snapshot.teams.length > 0) {
        setSelectedTeamId(snapshot.teams[0].id);
      }
    }
  }, [snapshot.teams, selectedTeamId]);

  const selectedTeam = snapshot.teams.find((t) => t.id === selectedTeamId) || snapshot.teams[0];

  const triggerFlash = (teamId: string, direction: 'up' | 'down') => {
    setFlashes((prev) => ({ ...prev, [teamId]: direction }));
    setTimeout(() => {
      setFlashes((prev) => ({ ...prev, [teamId]: null }));
    }, 600);
  };

  const handleManualRefetch = async () => {
    try {
      setIsRefetching(true);
      await onRefetch();
    } finally {
      setIsRefetching(false);
    }
  };

  const handleError = (err: any, expectedVer?: number, actionName = 'Action', retryFn?: () => void) => {
    const code = err?.code || '';
    const msg = err?.message || '';

    if (code === 'VERSION_CONFLICT' || msg.includes('VERSION_CONFLICT')) {
      setConflictDetails({
        expectedVersion: expectedVer ?? selectedTeam?.version,
        currentVersion: err?.detail?.current_version ?? (selectedTeam?.version ? selectedTeam.version + 1 : undefined),
        cash: err?.detail?.cash,
        cv: err?.detail?.cv,
      });
      return;
    }

    if (code === 'INSUFFICIENT_CASH' || msg.includes('INSUFFICIENT_CASH')) {
      const shortfall = err?.detail?.shortfall || 0;
      setInsufficientCashShortfall(shortfall);
      errorToast(`Insufficient cash! Shortfall: ₹${shortfall}`);
      setIsAddOpen(false);
      setUpgradeBizKey(null);
      return;
    }

    errorToast(msg || 'An error occurred.');
    if (retryFn) {
      setLastFailedAction({
        label: actionName,
        retry: retryFn,
        error: msg || 'Failed to save changes.',
      });
    }
  };

  // --- KEYBOARD SHORTCUTS ---
  // R = Rent, S = Start, B = Buy, U = Upgrade, Esc = Close dialogs
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const activeEl = document.activeElement;
      const isInput =
        activeEl &&
        (activeEl.tagName === 'INPUT' ||
          activeEl.tagName === 'TEXTAREA' ||
          activeEl.tagName === 'SELECT' ||
          (activeEl as HTMLElement).isContentEditable);

      if (e.key === 'Escape') {
        setIsRentOpen(false);
        setIsStartLapOpen(false);
        setIsStealOpen(false);
        setIsCardOpen(false);
        setIsLoseFeatureOpen(false);
        setIsForcedSaleOpen(false);
        return;
      }

      if (isInput) return;

      const key = e.key.toLowerCase();
      if (key === 'r') {
        e.preventDefault();
        setIsRentOpen(true);
      } else if (key === 's') {
        e.preventDefault();
        setIsStartLapOpen(true);
      } else if (key === 'b') {
        e.preventDefault();
        setIsAddOpen(true);
      } else if (key === 'u') {
        e.preventDefault();
        if (selectedTeam.businesses.length > 0) {
          setUpgradeBizKey(selectedTeam.businesses[0].business_key);
        } else {
          errorToast(`${selectedTeam.name} has no businesses to upgrade.`);
        }
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [selectedTeam, errorToast]);

  // --- MUTATION HANDLERS ---

  const handleQuickAdjust = async (params: {
    changes: Array<{
      team_id: string;
      cash_delta: number;
      cv_delta: number;
      expected_version: number;
    }>;
    label: string;
    note?: string;
    requestId: string;
  }) => {
    try {
      await rpcAdminAdjust({
        changes: params.changes,
        label: params.label,
        note: params.note,
        request_id: params.requestId,
      });
      successToast(`Action ${params.label} recorded.`);
      params.changes.forEach((ch) => {
        triggerFlash(ch.team_id, ch.cash_delta >= 0 ? 'up' : 'down');
      });
      setInsufficientCashShortfall(null);
      await onRefetch();
    } catch (err: any) {
      handleError(err);
      throw err;
    }
  };

  const handleForcedSaleBusiness = async ({
    teamId,
    businessKey,
    expectedVersion,
    note,
  }: {
    teamId: string;
    businessKey: string;
    expectedVersion: number;
    note?: string;
  }) => {
    try {
      await rpcAdminRemoveBusiness({
        team_id: teamId,
        business_key: businessKey,
        reason: 'FORCED_SALE',
        credit_resale: true,
        expected_version: expectedVersion,
        request_id: safeRandomUUID(),
        note,
      });
      const t = snapshot.teams.find((tm) => tm.id === teamId);
      successToast(`Sold ${businessKey} for ${t?.name || 'team'}.`);
      triggerFlash(teamId, 'up');
      setInsufficientCashShortfall(null);
      await onRefetch();
    } catch (err: any) {
      handleError(err, expectedVersion);
      throw err;
    }
  };

  const handleDoForcedSale = (teamId: string, shortfall: number) => {
    setIsRentOpen(false);
    setIsCardOpen(false);
    setIsStealOpen(false);
    setForcedSaleTeamId(teamId);
    setForcedSaleShortfall(shortfall);
    setIsForcedSaleOpen(true);
  };

  const handleDeclareBankrupt = (teamId: string) => {
    setIsRentOpen(false);
    setIsCardOpen(false);
    setIsStealOpen(false);
    setIsForcedSaleOpen(false);
    setSelectedTeamId(teamId);
    setBankruptMode('declare');
  };

  const handleUpdateCash = async (newCash: number, note?: string) => {
    if (!selectedTeam) return;
    const direction = newCash >= selectedTeam.cash ? 'up' : 'down';
    try {
      await rpcAdminSetTeamValues({
        team_id: selectedTeam.id,
        cash: newCash,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`${selectedTeam.name} cash updated.`);
      triggerFlash(selectedTeam.id, direction);
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleUpdateCv = async (newCv: number, note?: string) => {
    if (!selectedTeam) return;
    const direction = newCv >= selectedTeam.cv ? 'up' : 'down';
    try {
      await rpcAdminSetTeamValues({
        team_id: selectedTeam.id,
        cv: newCv,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`${selectedTeam.name} CV updated.`);
      triggerFlash(selectedTeam.id, direction);
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleAddBusiness = async ({
    businessKey,
    applyPurchase,
    note,
  }: {
    businessKey: string;
    applyPurchase: boolean;
    note?: string;
  }) => {
    if (!selectedTeam) return;
    try {
      await rpcAdminAddBusiness({
        team_id: selectedTeam.id,
        business_key: businessKey,
        apply_purchase: applyPurchase,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`Added business to ${selectedTeam.name}.`);
      triggerFlash(selectedTeam.id, 'up');
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleUpgradeBusiness = async ({
    businessKey,
    newLevel,
    applyUpgrade,
    note,
  }: {
    businessKey: string;
    newLevel: number;
    applyUpgrade: boolean;
    note?: string;
  }) => {
    if (!selectedTeam) return;
    try {
      await rpcAdminSetBusinessLevel({
        team_id: selectedTeam.id,
        business_key: businessKey,
        new_level: newLevel,
        apply_upgrade: applyUpgrade,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`Upgraded ${businessKey} for ${selectedTeam.name}.`);
      triggerFlash(selectedTeam.id, 'up');
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleEditBusiness = async ({
    businessKey,
    newLevel,
    note,
  }: {
    businessKey: string;
    newLevel: number;
    note: string;
  }) => {
    if (!selectedTeam) return;
    try {
      await rpcAdminSetBusinessLevel({
        team_id: selectedTeam.id,
        business_key: businessKey,
        new_level: newLevel,
        apply_upgrade: false,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`Corrected ${businessKey} level for ${selectedTeam.name}.`);
      triggerFlash(selectedTeam.id, 'up');
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleRemoveBusiness = async ({
    businessKey,
    reason,
    creditResale,
    note,
  }: {
    businessKey: string;
    reason: 'FORCED_SALE' | 'CORRECTION';
    creditResale: boolean;
    note?: string;
  }) => {
    if (!selectedTeam) return;
    try {
      await rpcAdminRemoveBusiness({
        team_id: selectedTeam.id,
        business_key: businessKey,
        reason,
        credit_resale: creditResale,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(`Removed ${businessKey} from ${selectedTeam.name}.`);
      triggerFlash(selectedTeam.id, reason === 'FORCED_SALE' ? 'up' : 'down');
      setInsufficientCashShortfall(null);
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  const handleBankrupt = async ({
    value,
    note,
  }: {
    value: boolean;
    note?: string;
  }) => {
    if (!selectedTeam) return;
    try {
      await rpcAdminSetBankrupt({
        team_id: selectedTeam.id,
        value,
        expected_version: selectedTeam.version,
        request_id: safeRandomUUID(),
        note,
      });
      successToast(
        value
          ? `${selectedTeam.name} marked as bankrupt.`
          : `${selectedTeam.name} bankruptcy revoked.`
      );
      triggerFlash(selectedTeam.id, value ? 'down' : 'up');
      await onRefetch();
    } catch (err: any) {
      handleError(err, selectedTeam.version);
      throw err;
    }
  };

  if (snapshot.room.status === 'FINALIZED') {
    return (
      <ResultView
        snapshot={snapshot}
        connection={connection}
        lastUpdated={lastUpdated}
        onRefetch={onRefetch}
      />
    );
  }

  if (!selectedTeam) return null;

  return (
    <div className="flex flex-col min-h-screen bg-[#5C94FC] text-[#102040]">
      {/* 1. TOP BAR */}
      <ConsoleTopBar
        roomCode={snapshot.room.code}
        status={snapshot.room.status}
        endsAt={snapshot.room.ends_at}
        serverNow={snapshot.server_now}
        connection={connection}
        lastUpdated={lastUpdated}
        onRefetch={handleManualRefetch}
        isRefetching={isRefetching}
        onAbortGame={(isActive || isTimeExpired) ? handleOpenAbort : undefined}
      />

      {/* Responsive width notice for small devices (< 1024px) */}
      <div className="lg:hidden bg-[#FFCC00] text-[#102040] px-4 py-2.5 text-center border-b-4 border-[#102040] shadow-[0_2px_0px_#102040]">
        <p className="font-pixel text-[11px] leading-relaxed">
          💻 Use a laptop for the admin console. Full operations grid is optimized for screens ≥ 1024px.
        </p>
      </div>

      {/* 2. FULL-WIDTH SYSTEM ALERTS */}
      {isOffline && (
        <div className="bg-[#D32F2F] text-white px-4 py-2 text-center font-pixel text-xs border-b-2 border-[#102040]">
          ⚠ OFFLINE — Edits disabled until internet connection is restored.
        </div>
      )}

      {!isOffline && isStaleData && (
        <div className="bg-[#FEF9C3] text-[#854D0E] px-4 py-2 text-center font-pixel text-xs border-b-2 border-[#102040]">
          ⚠ SCOREBOARD DATA IS STALE ({staleAgeSeconds}s old) — Edits disabled until connection is restored to prevent conflicts.
        </div>
      )}

      {lastFailedAction && (
        <div className="bg-[#FEE2E2] text-[#991B1B] border-b-2 border-[#102040] p-2.5 px-4 font-mono text-xs font-bold flex items-center justify-between shadow-[0_2px_0px_#102040]">
          <div className="flex items-center gap-2">
            <span>⚠ Not saved ({lastFailedAction.label}): {lastFailedAction.error}</span>
          </div>
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={lastFailedAction.retry}
              className="bg-[#D32F2F] text-white px-2.5 py-1 font-pixel text-[10px] uppercase border border-[#102040] hover:bg-[#B71C1C] cursor-pointer"
            >
              RETRY
            </button>
            <button
              type="button"
              onClick={() => setLastFailedAction(null)}
              className="font-pixel text-[10px] text-[#102040] hover:underline cursor-pointer"
            >
              DISMISS
            </button>
          </div>
        </div>
      )}

      {isTimeExpired && (
        <div className="bg-[#FFCC00] text-[#102040] px-4 py-2 text-center font-pixel text-xs border-b-4 border-[#102040] shadow-[0_2px_0px_#102040]">
          🏁 GAME OVER — scores frozen (50:00 Time Up). Resolve any ties below and click FINALIZE MATCH to certify official winners.
        </div>
      )}

      {insufficientCashShortfall !== null && (
        <div className="bg-[#FEECEB] border-b-3 border-[#D32F2F] p-3 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <span className="font-pixel text-xs text-[#D32F2F]">⚠ INSUFFICIENT CASH</span>
            <span className="font-mono text-xs text-[#102040]">
              Shortfall of <strong>₹{insufficientCashShortfall.toLocaleString('en-IN')}</strong>. Team must perform a forced sale first.
            </span>
          </div>
          {selectedTeam.businesses.length > 0 && (
            <button
              type="button"
              onClick={() => {
                setForcedSaleTeamId(selectedTeam.id);
                setForcedSaleShortfall(insufficientCashShortfall);
                setIsForcedSaleOpen(true);
              }}
              className="
                font-pixel text-[11px] uppercase px-3 py-1 bg-[#D32F2F] text-white
                border border-[#102040] shadow-[1px_1px_0px_#102040] hover:bg-[#B71C1C] cursor-pointer
              "
            >
              DO FORCED SALE FIRST
            </button>
          )}
        </div>
      )}

      {/* 3. MAIN DESKTOP CONSOLE BODY */}
      <main className="flex-1 w-full max-w-[1700px] mx-auto p-3 sm:p-4 lg:p-6 flex flex-col xl:flex-row gap-5">
        {/* Left & Center: Team Grid and Selected Team Editor */}
        <div className="flex-1 flex flex-col gap-5 min-w-0">
          {isTimeExpired && (
            <FinalizePanel
              roomId={snapshot.room.id}
              snapshot={snapshot}
              onRefetch={onRefetch}
              isOffline={isOffline}
            />
          )}

          <TeamGrid
            teams={snapshot.teams}
            selectedTeamId={selectedTeam.id}
            onSelectTeam={(id) => {
              setSelectedTeamId(id);
              setInsufficientCashShortfall(null);
            }}
            flashes={flashes}
          />

          <QuickActionsBar
            disabled={isEditDisabled}
            onOpenRent={() => setIsRentOpen(true)}
            onOpenStartLap={() => setIsStartLapOpen(true)}
            onOpenBuy={() => setIsAddOpen(true)}
            onOpenUpgrade={() => {
              if (selectedTeam.businesses.length > 0) {
                setUpgradeBizKey(selectedTeam.businesses[0].business_key);
              } else {
                errorToast(`${selectedTeam.name} has no businesses to upgrade.`);
              }
            }}
            onOpenForcedSale={() => {
              setForcedSaleTeamId(selectedTeam.id);
              setForcedSaleShortfall(undefined);
              setIsForcedSaleOpen(true);
            }}
            onOpenSteal={() => setIsStealOpen(true)}
            onOpenBonusCard={() => {
              setCardMode('BONUS');
              setIsCardOpen(true);
            }}
            onOpenCrisisCard={() => {
              setCardMode('CRISIS');
              setIsCardOpen(true);
            }}
            onOpenLoseFeature={() => setIsLoseFeatureOpen(true)}
          />

          <TeamEditor
            team={selectedTeam}
            isTimeExpired={isTimeExpired}
            disabled={isEditDisabled}
            onUpdateCash={handleUpdateCash}
            onUpdateCv={handleUpdateCv}
            onAddBusinessClick={() => setIsAddOpen(true)}
            onUpgradeBusinessClick={(key) => setUpgradeBizKey(key)}
            onEditBusinessClick={(key) => setEditBizKey(key)}
            onRemoveBusinessClick={(key) => setRemoveBizKey(key)}
            onOpenBankruptModal={(mode) => setBankruptMode(mode)}
          />
        </div>

        {/* Right Column: Live Activity Log */}
        <div className="w-full xl:w-[380px] 2xl:w-[440px] flex-shrink-0">
          <ActivityLog events={snapshot.events} teams={snapshot.teams} />
        </div>
      </main>

      {/* 4. MODALS & DIALOGS */}
      <AddBusinessDialog
        isOpen={isAddOpen}
        onClose={() => setIsAddOpen(false)}
        team={selectedTeam}
        allTeams={snapshot.teams}
        onSubmit={handleAddBusiness}
        isTimeExpired={isTimeExpired}
      />

      <UpgradeDialog
        isOpen={Boolean(upgradeBizKey)}
        onClose={() => setUpgradeBizKey(null)}
        businessKey={upgradeBizKey}
        team={selectedTeam}
        onSubmit={handleUpgradeBusiness}
        isTimeExpired={isTimeExpired}
      />

      <EditBusinessDialog
        isOpen={Boolean(editBizKey)}
        onClose={() => setEditBizKey(null)}
        businessKey={editBizKey}
        team={selectedTeam}
        onSubmit={handleEditBusiness}
      />

      <RemoveBusinessDialog
        isOpen={Boolean(removeBizKey)}
        onClose={() => setRemoveBizKey(null)}
        businessKey={removeBizKey}
        team={selectedTeam}
        onSubmit={handleRemoveBusiness}
        isTimeExpired={isTimeExpired}
      />

      <BankruptDialog
        isOpen={Boolean(bankruptMode)}
        onClose={() => setBankruptMode(null)}
        mode={bankruptMode || 'declare'}
        team={selectedTeam}
        onSubmit={handleBankrupt}
        isTimeExpired={isTimeExpired}
      />

      <ConflictDialog
        isOpen={Boolean(conflictDetails)}
        onClose={() => setConflictDetails(null)}
        onReload={handleManualRefetch}
        conflictDetails={conflictDetails}
      />

      {/* QUICK ACTIONS MODALS */}
      <RentDialog
        isOpen={isRentOpen}
        onClose={() => setIsRentOpen(false)}
        teams={snapshot.teams}
        defaultPayerId={selectedTeam.id}
        isTimeExpired={isTimeExpired}
        onSubmit={handleQuickAdjust}
        onDoForcedSale={handleDoForcedSale}
        onDeclareBankrupt={handleDeclareBankrupt}
      />

      <StartLapDialog
        isOpen={isStartLapOpen}
        onClose={() => setIsStartLapOpen(false)}
        teams={snapshot.teams}
        defaultTeamId={selectedTeam.id}
        isTimeExpired={isTimeExpired}
        onSubmit={handleQuickAdjust}
      />

      <StealDialog
        isOpen={isStealOpen}
        onClose={() => setIsStealOpen(false)}
        teams={snapshot.teams}
        defaultThiefId={selectedTeam.id}
        isTimeExpired={isTimeExpired}
        onSubmit={handleQuickAdjust}
        onDoForcedSale={handleDoForcedSale}
        onDeclareBankrupt={handleDeclareBankrupt}
      />

      <CardDialog
        isOpen={isCardOpen}
        onClose={() => setIsCardOpen(false)}
        teams={snapshot.teams}
        defaultTeamId={selectedTeam.id}
        defaultMode={cardMode}
        isTimeExpired={isTimeExpired}
        onSubmit={handleQuickAdjust}
        onDoForcedSale={handleDoForcedSale}
        onDeclareBankrupt={handleDeclareBankrupt}
      />

      <LoseFeatureDialog
        isOpen={isLoseFeatureOpen}
        onClose={() => setIsLoseFeatureOpen(false)}
        teams={snapshot.teams}
        defaultTeamId={selectedTeam.id}
        isTimeExpired={isTimeExpired}
        onSubmit={handleQuickAdjust}
      />

      <ForcedSaleDialog
        isOpen={isForcedSaleOpen}
        onClose={() => setIsForcedSaleOpen(false)}
        teams={snapshot.teams}
        defaultTeamId={forcedSaleTeamId || selectedTeam.id}
        shortfallTarget={forcedSaleShortfall}
        isTimeExpired={isTimeExpired}
        onSellBusiness={handleForcedSaleBusiness}
        onDeclareBankrupt={handleDeclareBankrupt}
      />

      {/* Abort Game Confirmation Modal */}
      <Modal
        isOpen={showAbortModal}
        onClose={() => setShowAbortModal(false)}
        title="ABORT GAME — RETURN TO LOBBY"
        footer={
          <>
            <PixelButton
              variant="ghost"
              size="md"
              onClick={() => setShowAbortModal(false)}
              disabled={isAborting}
            >
              CANCEL
            </PixelButton>
            <PixelButton
              variant="danger"
              size="md"
              disabled={!abortNote.trim() || isAborting}
              onClick={async () => {
                if (!abortNote.trim()) {
                  setAbortError('A reason note is required to abort the match.');
                  return;
                }
                try {
                  setIsAborting(true);
                  setAbortError(null);
                  await rpcAdminAbortGame(snapshot.room.id, abortNote.trim());
                  successToast('Game aborted. Room returned to LOBBY and teams reset.');
                  setShowAbortModal(false);
                  setAbortNote('');
                  await onRefetch();
                } catch (err: any) {
                  const msg = err?.message || 'Failed to abort game.';
                  setAbortError(msg);
                  errorToast(msg);
                } finally {
                  setIsAborting(false);
                }
              }}
              isLoading={isAborting}
            >
              CONFIRM ABORT
            </PixelButton>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          <p className="font-mono text-sm leading-relaxed text-[#102040]">
            This will <strong>reset the match back to LOBBY</strong>, stop the countdown timer, and <strong>reset all teams to baseline</strong>.
          </p>
          <div className="bg-[#FEF2F2] border-2 border-[#102040] p-3 text-xs text-[#991B1B] font-mono flex flex-col gap-1">
            <span className="font-bold">⚠ FULL TEAM RESET:</span>
            <span>All team cash resets to ₹1,000, CV resets to ₹0, all purchased businesses are removed, and bankruptcy flags are cleared.</span>
          </div>
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[10px] uppercase text-[#102040] font-bold">
              Mandatory Reason Note *
            </label>
            <input
              type="text"
              required
              placeholder="e.g. Accidental start, team not ready, tournament restart"
              value={abortNote}
              onChange={(e) => {
                setAbortNote(e.target.value);
                if (abortError) setAbortError(null);
              }}
              className="
                w-full px-2.5 py-1.5 font-sans text-xs text-[#102040] bg-white border-2 border-[#102040]
                focus:outline-none focus:ring-2 focus:ring-[#FFCC00]
              "
            />
          </div>
          {abortError && (
            <span className="font-mono text-xs text-[#D32F2F] font-bold">
              ⚠ {abortError}
            </span>
          )}
          <p className="font-mono text-xs text-[#64748B]">
            Use this if the match was started by mistake. You can start again from the lobby once ready.
          </p>
        </div>
      </Modal>

      {/* 5. NES Ground Pattern */}
      <div className="h-8 nes-brick-pattern border-t-4 border-[#102040]" />
    </div>
  );
};
