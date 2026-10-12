import { supabase } from './client';
import { parseRpcError, isNetworkError, isBusinessError } from '../lib/errors';
import { Database, Json } from './database.types';
import { logger } from '../lib/logger';

type FunctionName = keyof Database['public']['Functions'];

const READ_ONLY_RPCS = new Set<FunctionName>([
  'server_time',
  'get_lobby',
  'get_my_state',
  'get_admin_snapshot',
  'list_history',
  'get_history_detail',
  'get_standings',
]);

function canRetrySafely(fnName: FunctionName, args?: Record<string, unknown>): boolean {
  // Reads can be retried. Mutations require an idempotency key; otherwise a
  // lost response could apply a cash/CV/business mutation twice.
  return READ_ONLY_RPCS.has(fnName) || typeof args?.request_id === 'string';
}

async function callRpc<T>(fnName: FunctionName, args?: Record<string, unknown>, retryOnNetwork = true): Promise<T> {
  const retryAllowed = retryOnNetwork && canRetrySafely(fnName, args);
  try {
    const { data, error } = await (supabase.rpc as any)(fnName, args);
    if (error) {
      const parsed = parseRpcError(error);
      if (retryAllowed && isNetworkError(error) && !isBusinessError(parsed)) {
        logger.warn('RPC', `Network failure calling ${fnName}. Retrying safe request once...`);
        await new Promise((r) => setTimeout(r, 600));
        return callRpc<T>(fnName, args, false);
      }
      throw parsed;
    }
    return data as T;
  } catch (err) {
    const parsed = parseRpcError(err);
    if (retryAllowed && isNetworkError(err) && !isBusinessError(parsed)) {
      logger.warn('RPC', `Network error calling ${fnName}. Retrying safe request once...`);
      await new Promise((r) => setTimeout(r, 600));
      return callRpc<T>(fnName, args, false);
    }
    throw parsed;
  }
}

// 1. Core / Public
export async function rpcServerTime(): Promise<string> {
  return callRpc<string>('server_time');
}

// 2. Team Endpoints
export async function rpcGetLobby(code: string) {
  return callRpc<{
    status: string;
    team_count: number;
    teams: Array<{ slot: number; name: string; color: string; claimed: boolean }>;
  }>('get_lobby', { code });
}

export async function rpcJoinTeam(code: string, slot: number, pin: string) {
  return callRpc<{ team_id: string; room_id: string }>('join_team', { code, slot, pin });
}

export async function rpcGetMyState() {
  return callRpc<{
    room: { status: string; started_at: string | null; ends_at: string | null; server_now: string };
    team: { slot: number; name: string; color: string; cash: number; cv: number; is_bankrupt: boolean };
    businesses: Array<{
      business_key: string;
      name: string;
      level: number;
      cost: number;
      initial_cv: number;
      cv_contribution: number;
    }>;
    leaderboard: Array<{
      rank: number;
      name: string;
      color: string;
      cv: number;
      cash: number;
      business_count: number;
      is_bankrupt: boolean;
    }> | null;
  } | null>('get_my_state');
}

// 3. Admin Setup & Lifecycle
export async function rpcAdminCreateRoom(team_count: number, teams: Array<{ name: string; color: string }>) {
  return callRpc<any>('admin_create_room', { team_count, teams: teams as unknown as Json });
}

export async function rpcAdminUpdateTeamConfig(team_id: string, name: string, color: string) {
  return callRpc<any>('admin_update_team_config', { team_id, name, color });
}

export async function rpcAdminOpenLobby(room_id: string) {
  return callRpc<any>('admin_open_lobby', { room_id });
}

export async function rpcAdminReleaseTeam(team_id: string) {
  return callRpc<{ team_id: string; released: boolean }>('admin_release_team', { team_id });
}

export async function rpcAdminStartGame(room_id: string, force = false) {
  return callRpc<any>('admin_start_game', { room_id, force });
}

export async function rpcAdminAbortGame(room_id: string, note: string) {
  return callRpc<any>('admin_abort_game', { room_id, note });
}

// 4. Admin Edits
export async function rpcAdminSetTeamValues(params: {
  team_id: string;
  cash?: number | null;
  cv?: number | null;
  expected_version: number;
  request_id?: string;
  note?: string;
}) {
  return callRpc<any>('admin_set_team_values', params);
}

export async function rpcAdminAdjust(params: {
  changes: Array<{ team_id: string; cash_delta: number; cv_delta: number; expected_version: number }>;
  label: string;
  note?: string;
  request_id?: string;
}) {
  return callRpc<any>('admin_adjust', {
    changes: params.changes as unknown as Json,
    label: params.label,
    note: params.note,
    request_id: params.request_id,
  });
}

export async function rpcAdminAddBusiness(params: {
  team_id: string;
  business_key: string;
  apply_purchase?: boolean;
  expected_version: number;
  request_id?: string;
  note?: string;
}) {
  return callRpc<any>('admin_add_business', params);
}

export async function rpcAdminSetBusinessLevel(params: {
  team_id: string;
  business_key: string;
  new_level: number;
  apply_upgrade?: boolean;
  expected_version: number;
  request_id?: string;
  note?: string;
}) {
  return callRpc<any>('admin_set_business_level', params);
}

export async function rpcAdminRemoveBusiness(params: {
  team_id: string;
  business_key: string;
  reason: 'FORCED_SALE' | 'BANKRUPTCY' | 'CORRECTION';
  credit_resale?: boolean;
  expected_version: number;
  request_id?: string;
  note?: string;
}) {
  return callRpc<any>('admin_remove_business', params);
}

export async function rpcAdminSetBankrupt(params: {
  team_id: string;
  value: boolean;
  expected_version: number;
  request_id?: string;
  note?: string;
}) {
  return callRpc<any>('admin_set_bankrupt', params);
}

export async function rpcAdminSetTiebreak(room_id: string, ordered_team_ids: string[], note?: string) {
  return callRpc<any>('admin_set_tiebreak', { room_id, ordered_team_ids, note });
}

export interface AdminRoomSnapshot {
  room: {
    id: string;
    code: string;
    status: 'CREATED' | 'LOBBY' | 'ACTIVE' | 'TIME_EXPIRED' | 'FINALIZED' | string;
    team_count: number;
    started_at: string | null;
    ends_at: string | null;
    created_at: string;
    created_by: string;
    finalized_at?: string | null;
    winner_team_id?: string | null;
    duration_seconds?: number;
  };
  server_now: string;
  teams: Array<{
    id: string;
    slot: number;
    name: string;
    color: string;
    cash: number;
    cv: number;
    is_bankrupt: boolean;
    version: number;
    tiebreak_order: number | null;
    claimed: boolean;
    pin?: string | null;
    businesses: Array<{
      business_key: string;
      name: string;
      level: number;
      cost: number;
      initial_cv: number;
    }>;
  }>;
  events: Array<{
    id: number;
    team_id: string | null;
    group_id: string | null;
    type: string;
    business_key?: string | null;
    prev: any;
    new: any;
    note?: string | null;
    is_correction: boolean;
    created_at: string;
  }>;
}

export interface StandingsRow {
  team_id: string;
  slot: number;
  name: string;
  rank: number;
  is_bankrupt: boolean;
  cv: number;
  cash: number;
  business_count: number;
  tiebreak_order: number | null;
  tie_unresolved: boolean;
}

export interface StandingsResponse {
  standings: StandingsRow[];
  has_unresolved_tie: boolean;
}

export interface HistoryRoomSummary {
  room_id: string;
  code: string;
  created_at: string;
  finalized_at: string;
  winner_name: string | null;
  winner_color: string | null;
  team_count: number;
}

export interface HistoryDetailResult {
  team_id: string;
  rank: number;
  name: string;
  color: string;
  cv: number;
  cash: number;
  business_count: number;
  is_bankrupt: boolean;
}

export interface HistoryDetailResponse {
  room: {
    id: string;
    code: string;
    status: string;
    team_count: number;
    started_at: string | null;
    ends_at: string | null;
    created_at: string;
    finalized_at: string | null;
    winner_team_id: string | null;
    tiebreak_note?: string | null;
  };
  results: HistoryDetailResult[];
  events: AdminRoomSnapshot['events'];
}

// 5. Admin Inspection, Standings & History
export async function rpcGetAdminSnapshot(room_id: string): Promise<AdminRoomSnapshot> {
  return callRpc<AdminRoomSnapshot>('get_admin_snapshot', { room_id });
}

export async function rpcGetStandings(room_id: string): Promise<StandingsResponse> {
  return callRpc<StandingsResponse>('get_standings', { p_room_id: room_id });
}

export async function rpcAdminFinalize(room_id: string) {
  return callRpc<{
    room_id: string;
    winner_team_id: string | null;
    standings: StandingsRow[];
  }>('admin_finalize', { p_room_id: room_id });
}

export async function rpcListHistory(): Promise<HistoryRoomSummary[]> {
  return callRpc<HistoryRoomSummary[]>('list_history');
}

export async function rpcGetHistoryDetail(room_id: string): Promise<HistoryDetailResponse> {
  return callRpc<HistoryDetailResponse>('get_history_detail', { room_id });
}

// Aliases and Convenience Types
export const getMyStateRpc = rpcGetMyState;
export const joinTeamRpc = rpcJoinTeam;
export const getLobbyRpc = rpcGetLobby;
export type TeamStateResponse = NonNullable<Awaited<ReturnType<typeof rpcGetMyState>>>;
