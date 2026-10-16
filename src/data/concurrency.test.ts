import { describe, it, expect, vi, beforeEach } from 'vitest';
import { supabase } from './client';
import {
  rpcAdminSetTeamValues,
  rpcAdminAdjust,
  rpcAdminAddBusiness,
} from './rpc';
import { safeRandomUUID } from '../lib/uuid';

vi.mock('./client', () => ({
  supabase: {
    rpc: vi.fn(),
  },
}));

describe('Concurrency & Optimistic Locking Guarantees', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('Optimistic Concurrency Control (OCC)', () => {
    it('propagates VERSION_CONFLICT error with stale vs fresh version payload', async () => {
      const mockRpc = vi.mocked(supabase.rpc as any);

      // Simulates Postgres raising VERSION_CONFLICT with current version detail
      const conflictError = {
        message: 'VERSION_CONFLICT',
        details: JSON.stringify({
          expected_version: 1,
          current_version: 2,
          cash: 1200,
          cv: 400,
        }),
      };

      mockRpc.mockResolvedValueOnce({
        data: null,
        error: conflictError,
      });

      await expect(
        rpcAdminSetTeamValues({
          team_id: 'team-uuid-1',
          cash: 1300,
          expected_version: 1,
          request_id: safeRandomUUID(),
        })
      ).rejects.toMatchObject({
        code: 'VERSION_CONFLICT',
        detail: {
          expected_version: 1,
          current_version: 2,
          cash: 1200,
          cv: 400,
        },
      });
    });
  });

  describe('Idempotency & Safe Retries', () => {
    it('retries once on network failure when request_id is supplied', async () => {
      const mockRpc = vi.mocked(supabase.rpc as any);
      const reqId = safeRandomUUID();

      // First call fails with transient network error (Failed to fetch)
      mockRpc.mockResolvedValueOnce({
        data: null,
        error: { message: 'Failed to fetch', name: 'TypeError' },
      });

      // Second call (retry) succeeds with existing snapshot
      const successData = {
        team: { id: 'team-uuid-1', cash: 1300, version: 2 },
      };
      mockRpc.mockResolvedValueOnce({
        data: successData,
        error: null,
      });

      const result = await rpcAdminSetTeamValues({
        team_id: 'team-uuid-1',
        cash: 1300,
        expected_version: 1,
        request_id: reqId,
      });

      expect(mockRpc).toHaveBeenCalledTimes(2);
      expect(result).toEqual(successData);
    });

    it('does NOT retry mutations when request_id is missing to avoid double execution', async () => {
      const mockRpc = vi.mocked(supabase.rpc as any);

      // Mutation without request_id fails with network error
      mockRpc.mockResolvedValueOnce({
        data: null,
        error: { message: 'Failed to fetch', name: 'TypeError' },
      });

      await expect(
        rpcAdminAddBusiness({
          team_id: 'team-uuid-1',
          business_key: 'b1',
          expected_version: 1,
          // request_id omitted
        })
      ).rejects.toThrow();

      // Must not have retried
      expect(mockRpc).toHaveBeenCalledTimes(1);
    });
  });

  describe('Multi-Team Atomic Adjustment Concurrency', () => {
    it('correctly passes atomic multi-team adjustments to backend RPC', async () => {
      const mockRpc = vi.mocked(supabase.rpc as any);
      const reqId = safeRandomUUID();

      const changes = [
        {
          team_id: '11111111-0000-0000-0000-000000000001',
          cash_delta: -100,
          cv_delta: 0,
          expected_version: 3,
        },
        {
          team_id: '22222222-0000-0000-0000-000000000002',
          cash_delta: 100,
          cv_delta: 150,
          expected_version: 5,
        },
      ];

      mockRpc.mockResolvedValueOnce({
        data: [{ id: '11111111-0000-0000-0000-000000000001' }, { id: '22222222-0000-0000-0000-000000000002' }],
        error: null,
      });

      const res = await rpcAdminAdjust({
        changes,
        label: 'RENT',
        note: 'Team 1 paid rent to Team 2',
        request_id: reqId,
      });

      expect(mockRpc).toHaveBeenCalledWith('admin_adjust', {
        changes,
        label: 'RENT',
        note: 'Team 1 paid rent to Team 2',
        request_id: reqId,
      });
      expect(res).toHaveLength(2);
    });
  });
});
