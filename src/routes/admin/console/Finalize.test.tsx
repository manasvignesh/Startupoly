import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { StandingsTable } from './StandingsTable';
import { FinalizePanel } from './FinalizePanel';
import { ResultView } from './ResultView';
import { ToastProvider } from '../../../ui';
import * as rpcModule from '../../../data/rpc';

vi.mock('../../../data/rpc', async () => {
  const actual = await vi.importActual('../../../data/rpc');
  return {
    ...actual,
    rpcGetStandings: vi.fn(),
    rpcAdminFinalize: vi.fn(),
    rpcAdminCancelRoom: vi.fn(),
  };
});

const mockStandings: rpcModule.StandingsRow[] = [
  {
    team_id: 'team-1',
    slot: 1,
    name: 'Alpha Rockets',
    rank: 1,
    is_bankrupt: false,
    debt: 0,
    cash: 500,
    business_count: 3,
    business_cost: 0,
    upgrade_count: 0,
  },
  {
    team_id: 'team-2',
    slot: 2,
    name: 'Beta Builders',
    rank: 2,
    is_bankrupt: false,
    debt: 0,
    cash: 300,
    business_count: 2,
    business_cost: 0,
    upgrade_count: 0,
  },
  {
    team_id: 'team-3',
    slot: 3,
    name: 'Gamma Guild',
    rank: 3,
    is_bankrupt: false,
    debt: 0,
    cash: 300,
    business_count: 2,
    business_cost: 0,
    upgrade_count: 0,
  },
];

const mockSnapshot: rpcModule.AdminRoomSnapshot = {
  room: {
    id: 'room-1',
    code: 'REC123',
    status: 'TIME_EXPIRED',
    team_count: 3,
    started_at: '2026-09-21T10:00:00Z',
    ends_at: '2026-09-21T10:50:00Z',
    created_at: '2026-09-21T09:50:00Z',
    created_by: 'admin-1',
  },
  server_now: new Date().toISOString(),
  teams: [
    {
      id: 'team-1',
      slot: 1,
      name: 'Alpha Rockets',
      color: '#E52521',
      cash: 1500,
      debt: 0,
      is_bankrupt: false,
      version: 1,
      tiebreak_order: null,
      claimed: true,
      businesses: [],
    },
    {
      id: 'team-2',
      slot: 2,
      name: 'Beta Builders',
      color: '#22B14C',
      cash: 1200,
      debt: 0,
      is_bankrupt: false,
      version: 1,
      tiebreak_order: null,
      claimed: true,
      businesses: [],
    },
    {
      id: 'team-3',
      slot: 3,
      name: 'Gamma Guild',
      color: '#FFCC00',
      cash: 1200,
      debt: 0,
      is_bankrupt: false,
      version: 1,
      tiebreak_order: null,
      claimed: true,
      businesses: [],
    },
  ],
  events: [],
};

describe('StandingsTable', () => {
  it('renders ranks, names and the ranking criteria columns', () => {
    render(<StandingsTable standings={mockStandings} teams={mockSnapshot.teams} />);

    expect(screen.getByText('Alpha Rockets')).toBeInTheDocument();
    expect(screen.getByText('Beta Builders')).toBeInTheDocument();
    expect(screen.getByText('Gamma Guild')).toBeInTheDocument();

    expect(screen.getByRole('columnheader', { name: 'BIZ COST' })).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'UPGRADES' })).toBeInTheDocument();
    expect(screen.queryByText(/TIE STATUS|UNRESOLVED TIE/i)).not.toBeInTheDocument();
  });
});

describe('FinalizePanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('lets tied teams finalize without a judged order and confirms finalization', async () => {
    const resolvedStandings = mockStandings;
    vi.mocked(rpcModule.rpcGetStandings).mockResolvedValue({ standings: resolvedStandings });
    vi.mocked(rpcModule.rpcAdminFinalize).mockResolvedValue({
      room_id: 'room-1',
      winner_team_id: 'team-1',
      standings: resolvedStandings,
    });
    const onRefetch = vi.fn().mockResolvedValue(undefined);

    render(
      <ToastProvider>
        <FinalizePanel
          roomId="room-1"
          snapshot={mockSnapshot}
          onRefetch={onRefetch}
        />
      </ToastProvider>
    );

    expect(await screen.findByText(/Equal teams share a rank/i)).toBeInTheDocument();
    const finalizeBtn = screen.getByRole('button', { name: /FINALIZE MATCH/i });
    expect(finalizeBtn).not.toBeDisabled();

    // Click to open confirm modal
    fireEvent.click(finalizeBtn);
    expect(screen.getByText(/PERMANENTLY FINALIZE MATCH/i)).toBeInTheDocument();
    expect(screen.getByText(/IRREVERSIBLE ACTION/i)).toBeInTheDocument();

    // Confirm
    fireEvent.click(screen.getByRole('button', { name: /CONFIRM FINALIZATION/i }));
    expect(rpcModule.rpcAdminFinalize).toHaveBeenCalledWith('room-1');
  });

  it('falls back to rpcAdminCancelRoom when finalizing early during ACTIVE match', async () => {
    const activeSnapshot: rpcModule.AdminRoomSnapshot = {
      ...mockSnapshot,
      room: {
        ...mockSnapshot.room,
        status: 'ACTIVE',
      },
    };
    vi.mocked(rpcModule.rpcGetStandings).mockResolvedValue({ standings: mockStandings });
    vi.mocked(rpcModule.rpcAdminFinalize).mockRejectedValue({
      code: 'INVALID_TRANSITION',
      message: 'Invalid room status transition requested.',
    });
    vi.mocked(rpcModule.rpcAdminCancelRoom).mockResolvedValue({
      room_id: 'room-1',
      status: 'FINALIZED',
      cancelled: true,
    });
    const onRefetch = vi.fn().mockResolvedValue(undefined);

    render(
      <ToastProvider>
        <FinalizePanel
          roomId="room-1"
          snapshot={activeSnapshot}
          onRefetch={onRefetch}
        />
      </ToastProvider>
    );

    const finalizeBtn = await screen.findByRole('button', { name: /FINALIZE MATCH/i });
    await waitFor(() => expect(finalizeBtn).not.toBeDisabled());
    fireEvent.click(finalizeBtn);
    const confirmBtn = await screen.findByRole('button', { name: /CONFIRM FINALIZATION/i });
    fireEvent.click(confirmBtn);

    await waitFor(() => {
      expect(rpcModule.rpcAdminFinalize).toHaveBeenCalledWith('room-1');
      expect(rpcModule.rpcAdminCancelRoom).toHaveBeenCalledWith('room-1', 'Match finalized early by host');
      expect(onRefetch).toHaveBeenCalled();
    });
  });
});

describe('ResultView', () => {
  it('renders final leaderboard, winner, and Start New Match button', async () => {
    vi.mocked(rpcModule.rpcGetStandings).mockResolvedValue({ standings: mockStandings });

    const finalizedSnapshot: rpcModule.AdminRoomSnapshot = {
      ...mockSnapshot,
      room: {
        ...mockSnapshot.room,
        status: 'FINALIZED',
        finalized_at: '2026-09-21T11:00:00Z',
      },
    };

    render(
      <MemoryRouter>
        <ToastProvider>
          <ResultView
            snapshot={finalizedSnapshot}
            connection="LIVE"
            lastUpdated="Just now"
            onRefetch={vi.fn().mockResolvedValue(undefined)}
          />
        </ToastProvider>
      </MemoryRouter>
    );

    expect(await screen.findByText(/MATCH FINALIZED/i)).toBeInTheDocument();
    expect(screen.getByText(/START NEW MATCH/i)).toBeInTheDocument();
    expect(screen.getByText(/COPY RESULTS/i)).toBeInTheDocument();
    expect(screen.getByText(/CSV EXPORT/i)).toBeInTheDocument();
  });
});
