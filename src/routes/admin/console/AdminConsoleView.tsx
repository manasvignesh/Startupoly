import React, { useState, useEffect } from 'react';
import { ConsoleTopBar } from './ConsoleTopBar';
import { lifecycleAlreadyDone } from '../../../lib/lifecycle';
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
import { RoamingCharacter } from '../../../ui/pixel';
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
  rpcAdminExtendGame,
  rpcAdminMoveTeam,
  rpcAdminChargeRent,
  rpcRoomStatus,
} from '../../../data/rpc';
import {
  QuickActionsBar,
  RentDialog,
  StealDialog,
  CardDialog,
  LoseFeatureDialog,
  ForcedSaleDialog,
} from './quick';
import { PitchTimerModal } from './PitchTimerModal';
import { WildcardModal } from './WildcardModal';
import { TimeOverModal } from './TimeOverModal';
import { useStandings } from '../../../data/useStandings';
import { sounds } from '../../../lib/sound';
import { safeRandomUUID } from '../../../lib/uuid';
import { FinalizePanel } from './FinalizePanel';
import { ResultView } from './ResultView';
import { LiveBoardPanel } from './LiveBoardPanel';
import { BoardSpace, BOARD_SPACES, TOTAL_BOARD_SPACES, getBoardSpace } from '../../../domain/board';
import { computeRent } from '../../../domain/quickActions';
import { broadcastPropertySold, PropertySoldEvent } from '../../../data/broadcast';
import { PropertySoldModal } from '../../team/PropertySoldModal';
import { OFFICIAL_BUSINESSES } from '../../../domain/economy';

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
  const [soldEvent, setSoldEvent] = useState<PropertySoldEvent | null>(null);
  const [selectedTeamId, setSelectedTeamId] = useState<string>(
    snapshot.teams[0]?.id || ''
  );
  const [isRefetching, setIsRefetching] = useState<boolean>(false);
  const [flashes, setFlashes] = useState<Record<string, 'up' | 'down' | null>>({});
  const [soundEnabled, setSoundEnabled] = useState<boolean>(sounds.isEnabled());
  const [lastUndoableAction, setLastUndoableAction] = useState<{
    label: string;
    reversalChanges: Array<{
      team_id: string;
      cash_delta: number;
    }>;
  } | null>(null);

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
  const [rentDefaultBusinessKey, setRentDefaultBusinessKey] = useState<string | undefined>(undefined);
  const [isStealOpen, setIsStealOpen] = useState<boolean>(false);
  const [isCardOpen, setIsCardOpen] = useState<boolean>(false);
  const [cardMode, setCardMode] = useState<'BONUS' | 'CRISIS'>('BONUS');
  const [isLoseFeatureOpen, setIsLoseFeatureOpen] = useState<boolean>(false);
  const [isForcedSaleOpen, setIsForcedSaleOpen] = useState<boolean>(false);
  const [forcedSaleTeamId, setForcedSaleTeamId] = useState<string>('');
  const [forcedSaleShortfall, setForcedSaleShortfall] = useState<number | undefined>(undefined);

  // Arena & Field Modals
  const [isPitchTimerOpen, setIsPitchTimerOpen] = useState<boolean>(false);
  const [isWildcardOpen, setIsWildcardOpen] = useState<boolean>(false);

  // Conflict & Insufficient Cash states
  const [conflictDetails, setConflictDetails] = useState<{
    expectedVersion?: number;
    currentVersion?: number;
    cash?: number;
  } | null>(null);
  const [insufficientCashShortfall, setInsufficientCashShortfall] = useState<number | null>(null);

  const { successToast, errorToast, infoToast } = useToast();

  const isTimeExpired = snapshot.room.status === 'TIME_EXPIRED';
  const isActive = snapshot.room.status === 'ACTIVE';
  const isOffline = connection === 'OFFLINE';
  const isStaleData = isStale || staleAgeSeconds > 30;
  const isEditDisabled = isOffline || isStaleData;
  const [mobileOperationsTab, setMobileOperationsTab] = useState<'teams' | 'audit'>('teams');

  // Abort Game state
  const [showAbortModal, setShowAbortModal] = useState<boolean>(false);
  const [isAborting, setIsAborting] = useState<boolean>(false);
  const [abortNote, setAbortNote] = useState<string>('');
  const [abortError, setAbortError] = useState<string | null>(null);

  // Standings & Time Over states
  const { standings } = useStandings(snapshot.room.id, true);
  const [isTimeOverModalOpen, setIsTimeOverModalOpen] = useState<boolean>(false);
  const [isFinalizeModalOpen, setIsFinalizeModalOpen] = useState<boolean>(false);
  const [isExtendingTime, setIsExtendingTime] = useState<boolean>(false);
  const hasTriggeredTimeOverPopupRef = React.useRef<boolean>(false);

  useEffect(() => {
    if (isTimeExpired && !hasTriggeredTimeOverPopupRef.current) {
      hasTriggeredTimeOverPopupRef.current = true;
      setIsTimeOverModalOpen(true);
      sounds.playBuzzer();
    } else if (!isTimeExpired) {
      hasTriggeredTimeOverPopupRef.current = false;
    }
  }, [isTimeExpired]);

  const handleExtendTenMinutes = async () => {
    try {
      setIsExtendingTime(true);
      await rpcAdminExtendGame(snapshot.room.id, 600);
      sounds.playWhistle();
      successToast('⚡ Extra time active! Added 10 minutes to match clock.');
      setIsTimeOverModalOpen(false);
      await onRefetch();
    } catch (err: any) {
      errorToast(err?.message || 'Failed to extend match time.');
    } finally {
      setIsExtendingTime(false);
    }
  };

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
  const activeTeams = snapshot.teams.filter((t) => !t.is_bankrupt);
  const leader = snapshot.teams.reduce<(typeof snapshot.teams)[0] | undefined>(
    (best, t) => (t.debt > 0 || t.is_bankrupt ? best : !best || t.cash > best.cash ? t : best),
    undefined
  );
  const totalCash = snapshot.teams.reduce((n, t) => n + t.cash, 0);
  const totalBusinesses = snapshot.teams.reduce((n, t) => n + t.businesses.length, 0);

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

    if (code === 'OUTCOME_UNKNOWN') {
      // Neither success nor failure: show the neutral message, reload the truth, never claim it saved.
      infoToast(msg);
      void onRefetch();
      return;
    }

    if (code === 'ROOM_NOT_EDITABLE' || code === 'ROOM_ALREADY_EXPIRED' || code === 'INVALID_TRANSITION') {
      errorToast(msg || 'The match no longer accepts this change.');
      void onRefetch();
      return;
    }

    if (code === 'VERSION_CONFLICT' || msg.includes('VERSION_CONFLICT')) {
      setConflictDetails({
        expectedVersion: expectedVer ?? selectedTeam?.version,
        currentVersion: err?.detail?.current_version ?? (selectedTeam?.version ? selectedTeam.version + 1 : undefined),
        cash: err?.detail?.cash,
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
        setIsStealOpen(false);
        setIsCardOpen(false);
        setIsLoseFeatureOpen(false);
        setIsForcedSaleOpen(false);
        setIsPitchTimerOpen(false);
        setIsWildcardOpen(false);
        return;
      }

      if (isInput) return;

      const key = e.key.toLowerCase();

      // Undo hotkey: Ctrl+Z or Cmd+Z
      if ((e.ctrlKey || e.metaKey) && key === 'z') {
        e.preventDefault();
        void handleUndo();
        return;
      }

      if (key === 'r') {
        e.preventDefault();
        setIsRentOpen(true);
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
      } else if (key === 't') {
        e.preventDefault();
        setIsStealOpen(true);
      } else if (key === 'c') {
        e.preventDefault();
        setCardMode('BONUS');
        setIsCardOpen(true);
      } else if (key === 'x') {
        e.preventDefault();
        setCardMode('CRISIS');
        setIsCardOpen(true);
      } else if (key === 'l') {
        e.preventDefault();
        setIsLoseFeatureOpen(true);
      } else if (key === 'p') {
        e.preventDefault();
        setIsPitchTimerOpen(true);
      } else if (key === 'f') {
        e.preventDefault();
        setIsFinalizeModalOpen(true);
      } else if (key === 'w') {
        e.preventDefault();
        setIsWildcardOpen(true);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [selectedTeam, errorToast, lastUndoableAction]);

  // --- MUTATION HANDLERS ---

  const handleUndo = async () => {
    if (!lastUndoableAction) return;
    try {
      const changesWithVersions = lastUndoableAction.reversalChanges.map((rev) => {
        const currentTeam = snapshot.teams.find((t) => t.id === rev.team_id);
        return {
          team_id: rev.team_id,
          cash_delta: rev.cash_delta,
          expected_version: currentTeam?.version ?? 0,
        };
      });

      await rpcAdminAdjust({
        changes: changesWithVersions,
        label: `UNDO_${lastUndoableAction.label}`,
        note: `Correction: Undoing ${lastUndoableAction.label}`,
        request_id: safeRandomUUID(),
      });

      sounds.playDamage();
      successToast(`Reversed: ${lastUndoableAction.label}`);
      setLastUndoableAction(null);
      await onRefetch();
    } catch (err: any) {
      handleError(err, undefined, 'Undo');
    }
  };

  const handleQuickAdjust = async (params: {
    changes: Array<{
      team_id: string;
      cash_delta: number;
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

      // Play contextual audio feedback
      if (params.changes.some((c) => c.cash_delta > 0)) {
        sounds.playCoin();
      } else {
        sounds.playDamage();
      }

      // Record for 1-click Undo
      setLastUndoableAction({
        label: params.label,
        reversalChanges: params.changes.map((ch) => ({
          team_id: ch.team_id,
          cash_delta: -ch.cash_delta,
        })),
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

  const handleChargeRent = async (params: {
    payerTeamId: string;
    businessKey: string;
    payerExpectedVersion: number;
    ownerExpectedVersion: number;
    note?: string;
    requestId: string;
  }) => {
    const cashBefore = new Map(snapshot.teams.map((t) => [t.id, t.cash]));
    try {
      const result = await rpcAdminChargeRent({
        payer_team_id: params.payerTeamId,
        business_key: params.businessKey,
        payer_expected_version: params.payerExpectedVersion,
        owner_expected_version: params.ownerExpectedVersion,
        note: params.note,
        request_id: params.requestId,
      });
      // The server chose the amount: derive the undo and the flash from what it actually applied.
      const applied = (Array.isArray(result) ? result : []).map((r: { team: { id: string; cash: number } }) => ({
        team_id: r.team.id,
        cash_delta: r.team.cash - (cashBefore.get(r.team.id) ?? r.team.cash),
      }));
      sounds.playCoin();
      setLastUndoableAction({
        label: 'RENT',
        reversalChanges: applied.map((c) => ({ team_id: c.team_id, cash_delta: -c.cash_delta })),
      });
      successToast('Action RENT recorded.');
      applied.forEach((c) => triggerFlash(c.team_id, c.cash_delta >= 0 ? 'up' : 'down'));
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
      let currentVersion = selectedTeam.version;

      // In server-authoritative rules, a team must be standing on the business space to purchase it.
      // If the team has not moved yet on the Live Board, auto-move token to the business space first.
      const bizSpace = BOARD_SPACES.find((s) => s.businessKey === businessKey)?.index;
      const currentPos = selectedTeam.board_position ?? 0;
      if (applyPurchase && bizSpace !== undefined && currentPos !== bizSpace) {
        const steps = (bizSpace - currentPos + 24) % 24;
        if (steps > 0) {
          try {
            await rpcAdminMoveTeam({
              team_id: selectedTeam.id,
              steps,
              expected_version: currentVersion,
            });
            currentVersion += 1;
          } catch (moveErr) {
            console.warn('[AddBusiness] Auto-move failed, proceeding with add business:', moveErr);
          }
        }
      }

      await rpcAdminAddBusiness({
        team_id: selectedTeam.id,
        business_key: businessKey,
        apply_purchase: applyPurchase,
        expected_version: currentVersion,
        note,
      });
      const biz = OFFICIAL_BUSINESSES.find((b) => b.key === businessKey);
      const eventPayload: PropertySoldEvent = {
        teamName: selectedTeam.name,
        teamColor: selectedTeam.color,
        businessKey,
        businessName: biz?.name || businessKey,
        cost: biz?.cost || 0,
        timestamp: Date.now(),
      };
      setSoldEvent(eventPayload);
      void broadcastPropertySold(snapshot.room.code, eventPayload);
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

  const handleBoardMove = async (team: AdminRoomSnapshot['teams'][number], steps: number) => {
    try {
      const currentPos = team.board_position ?? 0;
      const rawTarget = currentPos + steps;
      const passedStart = rawTarget >= TOTAL_BOARD_SPACES;

      const res = await rpcAdminMoveTeam({
        team_id: team.id,
        steps,
        expected_version: team.version,
      });

      let updatedVersion = (res?.version ?? team.version + 1);
      let rewardAdded = false;

      if (res && typeof (res as any).start_reward === 'number' && (res as any).start_reward > 0) {
        rewardAdded = true;
      } else if (passedStart) {
        // Fallback: if database did not credit 200 (older migration), automatically credit +200:
        try {
          await rpcAdminAdjust({
            changes: [{ team_id: team.id, cash_delta: 200, expected_version: updatedVersion }],
            label: 'START',
            note: 'Passed START (+₹200)',
          });
          rewardAdded = true;
          updatedVersion += 1;
        } catch (adjustErr) {
          console.warn('[handleBoardMove] Fallback START cash reward failed:', adjustErr);
        }
      }

      if (passedStart || rewardAdded) {
        successToast(`🎉 ${team.name} passed START! +₹200 added to treasury.`);
      } else {
        successToast(`${team.name} moved ${steps} space${steps === 1 ? '' : 's'}.`);
      }

      setSelectedTeamId(team.id);
      await onRefetch();

      // Check if team landed on an opponent's business:
      const nextPos = (currentPos + steps) % TOTAL_BOARD_SPACES;
      const targetSpace = getBoardSpace(nextPos);
      if (targetSpace.type === 'BUSINESS' && targetSpace.businessKey) {
        const ownerTeam = snapshot.teams.find((t) => t.id !== team.id && t.businesses.some((b) => b.business_key === targetSpace.businessKey));
        if (ownerTeam) {
          const rentPreview = computeRent(team, targetSpace.businessKey, ownerTeam);
          const rentAmount = rentPreview.changes[1]?.cashDelta ?? (rentPreview.changes[0]?.cashDelta ? Math.abs(rentPreview.changes[0].cashDelta) : 0);
          errorToast(`🚨 ${team.name} landed on ${targetSpace.name} (Owned by ${ownerTeam.name})! Rent due: ₹${rentAmount.toLocaleString('en-IN')}`);
          setRentDefaultBusinessKey(targetSpace.businessKey);
          setIsRentOpen(true);
        }
      }
    } catch (err: any) {
      if (err?.code === 'PGRST202') {
        errorToast('Live Board is not installed on this game server yet. Apply the latest database migration, then reload.');
        return;
      }
      handleError(err, team.version, 'Move token');
      throw err;
    }
  };

  const handleResolveBoardSpace = (space: BoardSpace) => {
    switch (space.type) {
      case 'START':
        infoToast('START is paid automatically when a token reaches or passes it (+₹200).');
        break;
      case 'BUSINESS': {
        if (space.businessKey) {
          const ownerTeam = snapshot.teams.find((t) => t.businesses.some((b) => b.business_key === space.businessKey));
          if (ownerTeam && ownerTeam.id !== selectedTeam.id) {
            // Owned by another team! Directly open Rent Dialog pre-filled!
            setRentDefaultBusinessKey(space.businessKey);
            setIsRentOpen(true);
            return;
          }
          if (ownerTeam && ownerTeam.id === selectedTeam.id) {
            // Owned by self! Open Business Upgrade dialog if not max level
            const biz = ownerTeam.businesses.find((b) => b.business_key === space.businessKey);
            if (biz) {
              if (biz.level >= 2) {
                infoToast(`${biz.name} is already at max level (Level 2).`);
                return;
              }
              setUpgradeBizKey(biz.business_key);
              return;
            }
          }
        }
        setIsAddOpen(true);
        break;
      }
      case 'BONUS': setCardMode('BONUS'); setIsCardOpen(true); break;
      case 'CRISIS': setCardMode('CRISIS'); setIsCardOpen(true); break;
      case 'WILDCARD': setIsWildcardOpen(true); break;
      case 'ACTION_B': setIsPitchTimerOpen(true); break;
      case 'ACTION_C': setIsLoseFeatureOpen(true); break;
      case 'ACTION_D': setIsStealOpen(true); break;
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
    <div className="flex flex-col min-h-screen bg-brand-sky nes-sky-gradient text-brand-navy relative selection:bg-brand-gold selection:text-brand-navy">
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
        onExtendTenMinutes={handleExtendTenMinutes}
        isExtendingTime={isExtendingTime}
        onFinalizeMatch={() => setIsFinalizeModalOpen(true)}
      />

      {/* QUICK COMMAND STRIP */}
      <div className="bg-brand-navy border-b-2 border-brand-gold px-4 py-2 flex flex-wrap items-center justify-between gap-3 text-white shadow-pixel-sm">
        <div className="flex items-center gap-2 flex-wrap">
          <button
            type="button"
            onClick={() => setIsPitchTimerOpen(true)}
            title="30-second physical pitch timer for Action B & tiebreaks (Hotkey: P)"
            className="font-pixel text-[10px] bg-sky-600 text-white px-2.5 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-sky-500 active:translate-y-0.5 transition-colors uppercase flex items-center gap-1 cursor-pointer"
          >
            <span>🎤</span> 30s PITCH [P]
          </button>

          <button
            type="button"
            onClick={() => setIsWildcardOpen(true)}
            title="Draw random physical task for Wildcard space (Hotkey: W)"
            className="font-pixel text-[10px] bg-purple-600 text-white px-2.5 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-purple-500 active:translate-y-0.5 transition-colors uppercase flex items-center gap-1 cursor-pointer"
          >
            <span>🎲</span> WILDCARD [W]
          </button>

          <button
            type="button"
            onClick={() => setIsFinalizeModalOpen(true)}
            title="Finalize match and lock tournament results at any time"
            className="font-pixel text-[10px] bg-brand-gold text-brand-navy px-3 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-yellow-400 active:translate-y-0.5 transition-colors uppercase font-bold flex items-center gap-1 cursor-pointer"
          >
            <span>🏆</span> FINALIZE MATCH
          </button>

          {lastUndoableAction && (
            <button
              type="button"
              onClick={handleUndo}
              title={`Undo last action: ${lastUndoableAction.label} (Hotkey: Ctrl+Z)`}
              className="font-pixel text-[10px] bg-brand-red text-white px-3 py-1.5 border-2 border-white/60 shadow-pixel-sm hover:bg-interactive-red-hover active:translate-y-0.5 transition-colors uppercase font-bold flex items-center gap-1 cursor-pointer animate-pulse"
            >
              <span>↩️</span> UNDO: {lastUndoableAction.label} [Ctrl+Z]
            </button>
          )}
        </div>

        <div className="flex items-center gap-3">
          <span className="hidden xl:inline font-mono text-[10px] text-brand-gold/80">
            Keys: [1-6] Team • [S] Start • [R] Rent • [B] Buy • [U] Upgrade • [T] Steal • [C] Bonus • [X] Crisis • [P] Pitch
          </span>
          <button
            type="button"
            onClick={() => setSoundEnabled(sounds.toggle())}
            title="Toggle Sound FX"
            className="font-pixel text-[10px] bg-neutral-800 text-neutral-300 px-2.5 py-1 border border-neutral-600 hover:text-white cursor-pointer"
          >
            {soundEnabled ? '🔊 SOUND ON' : '🔇 MUTED'}
          </button>
        </div>
      </div>

      {/* 2. FULL-WIDTH SYSTEM ALERTS */}
      {isOffline && (
        <div className="bg-brand-red text-brand-white px-4 py-2 text-center font-pixel text-xs border-b-2 border-brand-navy">
          ⚠ OFFLINE — Edits disabled until internet connection is restored.
        </div>
      )}

      {!isOffline && isStaleData && (
        <div className="bg-status-warning-bg text-status-warning-dark px-4 py-2 text-center font-pixel text-xs border-b-2 border-brand-navy">
          ⚠ SCOREBOARD DATA IS STALE ({staleAgeSeconds}s old) — Edits disabled until connection is restored to prevent conflicts.
        </div>
      )}

      {lastFailedAction && (
        <div className="bg-status-danger-bg text-status-danger-dark border-b-2 border-brand-navy p-2.5 px-4 font-mono text-xs font-bold flex items-center justify-between shadow-pixel-sm">
          <div className="flex items-center gap-2">
            <span>⚠ Not saved ({lastFailedAction.label}): {lastFailedAction.error}</span>
          </div>
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={lastFailedAction.retry}
              className="bg-brand-red text-brand-white px-2.5 py-1 font-pixel text-[10px] uppercase border border-brand-navy hover:bg-interactive-red-hover cursor-pointer"
            >
              RETRY
            </button>
            <button
              type="button"
              onClick={() => setLastFailedAction(null)}
              className="font-pixel text-[10px] text-brand-navy hover:underline cursor-pointer"
            >
              DISMISS
            </button>
          </div>
        </div>
      )}

      {isTimeExpired && (
        <div className="bg-brand-gold border-b-4 border-brand-navy p-3 px-4 shadow-pixel flex flex-wrap items-center justify-between gap-3 text-brand-navy">
          <div className="flex items-center gap-2.5">
            <span className="text-xl">⏰</span>
            <div>
              <span className="font-pixel text-xs font-black uppercase tracking-wider block">
                🏁 GAME OVER — SCORES FROZEN
              </span>
              <span className="font-mono text-[11px] text-brand-navy/80 block">
                Gameplay time has expired. Grant +10 minutes extra time, or finalize results.
              </span>
            </div>
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            <button
              type="button"
              disabled={isExtendingTime}
              onClick={handleExtendTenMinutes}
              className="font-pixel text-xs bg-brand-green text-white px-3.5 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-interactive-green-hover active:translate-y-0.5 cursor-pointer uppercase font-bold flex items-center gap-1.5 transition-all disabled:opacity-50"
            >
              <span>⚡</span> {isExtendingTime ? 'EXTENDING...' : '+10 MINS EXTRA TIME [E]'}
            </button>
            <button
              type="button"
              onClick={() => {
                setIsTimeOverModalOpen(false);
                setIsFinalizeModalOpen(true);
              }}
              className="font-pixel text-xs bg-brand-navy text-brand-gold px-3.5 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-neutral-800 active:translate-y-0.5 cursor-pointer uppercase font-bold flex items-center gap-1.5 transition-all"
            >
              <span>🏆</span> REVIEW & FINALIZE [F]
            </button>
            <button
              type="button"
              onClick={() => setIsTimeOverModalOpen(true)}
              className="font-pixel text-xs bg-brand-cream text-brand-navy px-2.5 py-1.5 border-2 border-brand-navy shadow-pixel-sm hover:bg-brand-white cursor-pointer uppercase font-bold"
            >
              OPTIONS
            </button>
          </div>
        </div>
      )}

      {insufficientCashShortfall !== null && (
        <div className="bg-status-danger-bg border-b-3 border-brand-red p-3 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <span className="font-pixel text-xs text-brand-red">⚠ INSUFFICIENT CASH</span>
            <span className="font-mono text-xs text-brand-navy">
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
                font-pixel text-[11px] uppercase px-3 py-1 bg-brand-red text-brand-white
                border border-brand-navy shadow-pixel-sm hover:bg-interactive-red-hover cursor-pointer
              "
            >
              DO FORCED SALE FIRST
            </button>
          )}
        </div>
      )}

      {/* 3. MAIN DESKTOP CONSOLE BODY (FRAMED IN ARCADE BRICK PERIMETER) */}
      <main className="flex-1 w-full max-w-[1440px] mx-auto p-3 sm:p-5 lg:p-6 flex flex-col gap-5">
        <div className="border-4 sm:border-[8px] border-brand-brick shadow-[0_10px_0_var(--color-brand-navy)] bg-brand-cream/95 p-3 sm:p-5 lg:p-6 flex flex-col gap-5 min-w-0">
          {/* Match overview: sums of authoritative snapshot values */}
          <section aria-label="Match overview" className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
            {/* Card 1: TEAMS IN PLAY */}
            <div className="bg-brand-white border-3 sm:border-4 border-brand-navy shadow-pixel relative overflow-hidden p-3.5 sm:p-4 flex flex-col justify-between hover:-translate-y-0.5 transition-transform">
              <div className="flex items-center justify-between border-b-2 border-brand-navy/15 pb-2">
                <span className="font-pixel text-[10px] sm:text-[11px] text-brand-navy font-black uppercase tracking-wider flex items-center gap-1.5">
                  <span className="text-sm">🎮</span> TEAMS IN PLAY
                </span>
                <span className="w-2.5 h-2.5 rounded-full bg-brand-green border border-brand-navy animate-pulse" />
              </div>
              <div className="my-2.5">
                <span className="font-pixel text-2xl sm:text-3xl font-black text-brand-navy tabular-nums block">
                  {activeTeams.length}/{snapshot.teams.length}
                </span>
              </div>
              <span className="font-mono text-[10px] sm:text-xs text-neutral-500 block truncate font-bold">
                {snapshot.teams.length - activeTeams.length > 0
                  ? `${snapshot.teams.length - activeTeams.length} bankrupt`
                  : 'All slots active'}
              </span>
            </div>

            {/* Card 2: LEADER (TOTAL) */}
            <div className="bg-brand-white border-3 sm:border-4 border-brand-navy shadow-pixel relative overflow-hidden p-3.5 sm:p-4 flex flex-col justify-between hover:-translate-y-0.5 transition-transform ring-2 ring-brand-gold/60">
              <div className="flex items-center justify-between border-b-2 border-brand-navy/15 pb-2">
                <span className="font-pixel text-[10px] sm:text-[11px] text-brand-navy font-black uppercase tracking-wider flex items-center gap-1.5">
                  <span className="text-sm">👑</span> LEADER (TOTAL)
                </span>
                <span className="font-pixel text-[9px] bg-brand-gold text-brand-navy px-1.5 py-0.5 border border-brand-navy font-bold">
                  RANK #1
                </span>
              </div>
              <div className="my-2.5">
                <span className="font-pixel text-xl sm:text-2xl font-black text-brand-navy truncate block">
                  {leader ? leader.name : '—'}
                </span>
              </div>
              <span
                className="font-mono text-[10px] sm:text-xs text-neutral-600 block truncate font-bold"
                title={leader ? `₹${leader.cash.toLocaleString('en-IN')}` : ''}
              >
                {leader
                  ? `₹${leader.cash.toLocaleString('en-IN')} cash`
                  : 'No active teams'}
              </span>
            </div>

            {/* Card 3: CASH IN PLAY */}
            <div className="bg-brand-white border-3 sm:border-4 border-brand-navy shadow-pixel relative overflow-hidden p-3.5 sm:p-4 flex flex-col justify-between hover:-translate-y-0.5 transition-transform">
              <div className="flex items-center justify-between border-b-2 border-brand-navy/15 pb-2">
                <span className="font-pixel text-[10px] sm:text-[11px] text-brand-navy font-black uppercase tracking-wider flex items-center gap-1.5">
                  <span className="text-sm">🪙</span> CASH IN PLAY
                </span>
                <span className="font-mono text-[9px] bg-status-success-bg text-brand-green px-1.5 py-0.5 border border-brand-green font-bold">
                  LIQUID
                </span>
              </div>
              <div className="my-2.5">
                <span className="font-pixel text-2xl sm:text-3xl font-black text-brand-green tabular-nums block">
                  ₹{totalCash.toLocaleString('en-IN')}
                </span>
              </div>
              <span className="font-mono text-[10px] sm:text-xs text-neutral-500 block truncate font-bold">
                all teams
              </span>
            </div>

            {/* Card 4: BUSINESSES OWNED */}
            <div className="bg-brand-white border-3 sm:border-4 border-brand-navy shadow-pixel relative overflow-hidden p-3.5 sm:p-4 flex flex-col justify-between hover:-translate-y-0.5 transition-transform">
              <div className="flex items-center justify-between border-b-2 border-brand-navy/15 pb-2">
                <span className="font-pixel text-[10px] sm:text-[11px] text-brand-navy font-black uppercase tracking-wider flex items-center gap-1.5">
                  <span className="text-sm">🏢</span> BUSINESSES OWNED
                </span>
                <span className="font-mono text-[9px] bg-purple-100 text-purple-700 px-1.5 py-0.5 border border-purple-400 font-bold">
                  ASSETS
                </span>
              </div>
              <div className="my-2.5">
                <span className="font-pixel text-2xl sm:text-3xl font-black text-brand-navy tabular-nums block">
                  {totalBusinesses}
                </span>
              </div>
              <span className="font-mono text-[10px] sm:text-xs text-neutral-500 block truncate font-bold">
                across all teams
              </span>
            </div>
          </section>

          <QuickActionsBar
            disabled={isEditDisabled}
            onOpenRent={() => setIsRentOpen(true)}
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
            onOpenBonusCard={() => { setCardMode('BONUS'); setIsCardOpen(true); }}
            onOpenCrisisCard={() => { setCardMode('CRISIS'); setIsCardOpen(true); }}
            onOpenLoseFeature={() => setIsLoseFeatureOpen(true)}
            onOpenPitchTimer={() => setIsPitchTimerOpen(true)}
            onOpenWildcard={() => setIsWildcardOpen(true)}
            onUndo={handleUndo}
            canUndo={Boolean(lastUndoableAction)}
            lastUndoLabel={lastUndoableAction?.label}
          />

          <LiveBoardPanel
            teams={snapshot.teams}
            events={snapshot.events}
            selectedTeamId={selectedTeam.id}
            disabled={isEditDisabled || !isActive}
            onSelectTeam={(id) => {
              setSelectedTeamId(id);
              setInsufficientCashShortfall(null);
            }}
            onMoveTeam={handleBoardMove}
            onResolveSpace={handleResolveBoardSpace}
          />

          {/* Mobile Operations Tab Switcher (< md) */}
          <div className="flex md:hidden items-center border-2 border-brand-navy bg-brand-white p-1 shadow-pixel-sm">
            <button
              type="button"
              onClick={() => setMobileOperationsTab('teams')}
              className={`flex-1 py-2 font-pixel text-xs text-center border-2 uppercase font-bold transition-colors cursor-pointer ${
                mobileOperationsTab === 'teams'
                  ? 'bg-brand-gold text-brand-navy border-brand-navy shadow-pixel-sm'
                  : 'bg-transparent text-neutral-600 border-transparent hover:text-brand-navy'
              }`}
            >
              👥 TEAMS & ACTIONS
            </button>
            <button
              type="button"
              onClick={() => setMobileOperationsTab('audit')}
              className={`flex-1 py-2 font-pixel text-xs text-center border-2 uppercase font-bold transition-colors cursor-pointer ${
                mobileOperationsTab === 'audit'
                  ? 'bg-brand-gold text-brand-navy border-brand-navy shadow-pixel-sm'
                  : 'bg-transparent text-neutral-600 border-transparent hover:text-brand-navy'
              }`}
            >
              📋 LIVE AUDIT LOG ({snapshot.events.length})
            </button>
          </div>

          <div className={`flex flex-col gap-5 ${mobileOperationsTab === 'teams' ? 'flex' : 'hidden md:flex'}`}>
            <TeamGrid
              teams={snapshot.teams}
              selectedTeamId={selectedTeam.id}
              onSelectTeam={(id) => {
                setSelectedTeamId(id);
                setInsufficientCashShortfall(null);
              }}
              flashes={flashes}
            />

            <TeamEditor
              team={selectedTeam}
              isTimeExpired={isTimeExpired}
              disabled={isEditDisabled}
              onUpdateCash={handleUpdateCash}
              onAddBusinessClick={() => setIsAddOpen(true)}
              onUpgradeBusinessClick={(key) => setUpgradeBizKey(key)}
              onEditBusinessClick={(key) => setEditBizKey(key)}
              onRemoveBusinessClick={(key) => setRemoveBizKey(key)}
              onOpenBankruptModal={(mode) => setBankruptMode(mode)}
            />
          </div>

          <div className={`${mobileOperationsTab === 'audit' ? 'block' : 'hidden md:block'}`}>
            <ActivityLog events={snapshot.events} teams={snapshot.teams} collapsible />
          </div>

          {/* Match controls: lifecycle actions, kept apart from team operations */}
          <section aria-label="Match controls" className="border-4 border-brand-red bg-status-danger-bg/40 p-3 flex flex-col gap-3">
            <h2 className="font-pixel text-xs uppercase tracking-wider text-brand-red">MATCH CONTROLS</h2>
          <FinalizePanel
            roomId={snapshot.room.id}
            snapshot={snapshot}
            onRefetch={onRefetch}
            isOffline={isOffline}
            isModalOpen={isFinalizeModalOpen}
            onModalOpenChange={setIsFinalizeModalOpen}
          />

            {isActive && (
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-mono text-xs text-brand-navy">Started by mistake? Abort resets every team and returns the room to LOBBY.</span>
                <button
                  type="button"
                  onClick={handleOpenAbort}
                  className="font-pixel text-[10px] bg-brand-red text-white px-3 py-1.5 border-2 border-brand-navy hover:bg-interactive-red-hover active:translate-y-0.5 cursor-pointer uppercase tracking-wider"
                >
                  ✕ ABORT GAME
                </button>
              </div>
            )}
          </section>
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
        onClose={() => {
          setIsRentOpen(false);
          setRentDefaultBusinessKey(undefined);
        }}
        teams={snapshot.teams}
        defaultPayerId={selectedTeam.id}
        defaultBusinessKey={rentDefaultBusinessKey}
        isTimeExpired={isTimeExpired}
        onSubmit={handleChargeRent}
        onDoForcedSale={handleDoForcedSale}
        onDeclareBankrupt={handleDeclareBankrupt}
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

      {/* PITCH TIMER & WILDCARD MODALS */}
      <PitchTimerModal
        isOpen={isPitchTimerOpen}
        onClose={() => setIsPitchTimerOpen(false)}
        teamName={selectedTeam?.name}
      />

      <WildcardModal
        isOpen={isWildcardOpen}
        onClose={() => setIsWildcardOpen(false)}
        teamName={selectedTeam?.name}
      />

      {/* TIME OVER MODAL: EXTEND +10 MINS OR FINALIZE */}
      <TimeOverModal
        isOpen={isTimeOverModalOpen}
        onClose={() => setIsTimeOverModalOpen(false)}
        snapshot={snapshot}
        standings={standings}
        onExtendTenMinutes={handleExtendTenMinutes}
        onOpenFinalize={() => {
          setIsTimeOverModalOpen(false);
          setIsFinalizeModalOpen(true);
        }}
        isExtending={isExtendingTime}
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
                  if (await lifecycleAlreadyDone(err, snapshot.room.id, 'LOBBY', rpcRoomStatus)) {
                    successToast('Game aborted. Room returned to LOBBY and teams reset.');
                    setShowAbortModal(false);
                    setAbortNote('');
                    await onRefetch();
                    return;
                  }
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
          <p className="font-mono text-sm leading-relaxed text-brand-navy">
            This will <strong>reset the match back to LOBBY</strong>, stop the countdown timer, and <strong>reset all teams to baseline</strong>.
          </p>
          <div className="bg-status-danger-bg border-2 border-brand-navy p-3 text-xs text-status-danger-dark font-mono flex flex-col gap-1">
            <span className="font-bold">⚠ FULL TEAM RESET:</span>
            <span>All team cash resets to ₹1,000, all purchased businesses are removed, and bankruptcy flags are cleared.</span>
          </div>
          <div className="flex flex-col gap-1">
            <label className="font-pixel text-[10px] uppercase text-brand-navy font-bold">
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
                w-full px-2.5 py-1.5 font-sans text-xs text-brand-navy bg-brand-white border-2 border-brand-navy
                focus:outline-none focus:ring-2 focus:ring-brand-gold
              "
            />
          </div>
          {abortError && (
            <span className="font-mono text-xs text-brand-red font-bold">
              ⚠ {abortError}
            </span>
          )}
          <p className="font-mono text-xs text-neutral-500">
            Use this if the match was started by mistake. You can start again from the lobby once ready.
          </p>
        </div>
      </Modal>

      {/* Mascot Mario Patrols Ground */}
      <div className="w-full relative h-14 overflow-visible pointer-events-none select-none anim-mario-land">
        <div className="absolute inset-x-0 bottom-0 pointer-events-none">
          <RoamingCharacter size={46} variant="admin" />
        </div>
      </div>

      {/* 5. NES Ground Pattern */}
      <div className="h-8 nes-brick-pattern border-t-4 border-brand-navy" />

      {/* Property Acquired 3D Title Deed Card */}
      <PropertySoldModal event={soldEvent} onDismiss={() => setSoldEvent(null)} />
    </div>
  );
};
