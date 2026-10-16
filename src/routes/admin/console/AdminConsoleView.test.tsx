import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { AdminConsoleView } from './AdminConsoleView';
import * as rpcModule from '../../../data/rpc';
import { ToastProvider } from '../../../ui';

vi.mock('../../../data/rpc', async () => {
  const actual = await vi.importActual('../../../data/rpc');
  return {
    ...actual,
    rpcAdminSetTeamValues: vi.fn(),
    rpcAdminAddBusiness: vi.fn(),
    rpcAdminSetBusinessLevel: vi.fn(),
    rpcAdminRemoveBusiness: vi.fn(),
    rpcAdminSetBankrupt: vi.fn(),
    rpcAdminAbortGame: vi.fn(),
  };
});

describe('AdminConsoleView', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  const mockSnapshot: rpcModule.AdminRoomSnapshot = {
    room: {
      id: 'room-1',
      code: 'TEST88',
      status: 'ACTIVE',
      team_count: 5,
      started_at: '2026-09-21T10:00:00Z',
      ends_at: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
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
        cash: 1000,
        cv: 300,
        is_bankrupt: false,
        version: 1,
        tiebreak_order: null,
        claimed: true,
        businesses: [
          {
            business_key: 'saas',
            name: 'SaaS',
            level: 0,
            cost: 300,
            initial_cv: 180,
          },
        ],
      },
      {
        id: 'team-2',
        slot: 2,
        name: 'Beta Builders',
        color: '#0099FF',
        cash: 1500,
        cv: 800,
        is_bankrupt: false,
        version: 2,
        tiebreak_order: null,
        claimed: true,
        businesses: [
          {
            business_key: 'edtech',
            name: 'EdTech',
            level: 2,
            cost: 200,
            initial_cv: 150,
          },
        ],
      },
      {
        id: 'team-3',
        slot: 3,
        name: 'Gamma Gigabytes',
        color: '#22B14C',
        cash: 500,
        cv: 1200,
        is_bankrupt: true,
        version: 3,
        tiebreak_order: null,
        claimed: false,
        businesses: [],
      },
    ],
    events: [
      {
        id: 101,
        team_id: 'team-1',
        group_id: null,
        type: 'CASH_SET',
        prev: { cash: 900 },
        new: { cash: 1000 },
        is_correction: false,
        created_at: '2026-09-21T10:05:00Z',
      },
      {
        id: 102,
        team_id: 'team-2',
        group_id: null,
        type: 'BUSINESS_ADDED',
        business_key: 'edtech',
        prev: null,
        new: { apply_purchase: true },
        is_correction: false,
        created_at: '2026-09-21T10:10:00Z',
      },
    ],
  };

  const renderComponent = (props: Partial<React.ComponentProps<typeof AdminConsoleView>> = {}) => {
    const defaultProps = {
      snapshot: mockSnapshot,
      onRefetch: vi.fn().mockResolvedValue(undefined),
      connection: 'LIVE' as const,
      lastUpdated: 'Just now',
      ...props,
    };

    return render(
      <ToastProvider>
        <MemoryRouter>
          <AdminConsoleView {...defaultProps} />
        </MemoryRouter>
      </ToastProvider>
    );
  };

  it('renders all team cards, top bar, selected team editor, and activity log', () => {
    renderComponent();

    expect(screen.getByText('ROOM TEST88')).toBeInTheDocument();
    expect(screen.getAllByText('Alpha Rockets').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Beta Builders').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Gamma Gigabytes').length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText('LIVE ACTIVITY LOG')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: /SLOT #1: Alpha Rockets/i })).toBeInTheDocument();
  });

  it('handles cash update flow with inline confirm strip, diff calculation, and Enter confirm', async () => {
    vi.mocked(rpcModule.rpcAdminSetTeamValues).mockResolvedValue({} as any);
    renderComponent();

    // In Cash editor, click quick chip '+200' -> input becomes 1200
    const plus200Btn = screen.getAllByRole('button', { name: '+200' })[0];
    fireEvent.click(plus200Btn);

    // Click UPDATE
    const updateButtons = screen.getAllByRole('button', { name: 'UPDATE' });
    fireEvent.click(updateButtons[0]);

    // Confirm strip displays diff: ₹1,000 → ₹1,200 (+₹200)
    await waitFor(() => {
      expect(screen.getByText(/₹1,000 → ₹1,200/i)).toBeInTheDocument();
      expect(screen.getByText('+₹200')).toBeInTheDocument();
    });

    // Press Enter to confirm
    const confirmBtn = screen.getByRole('button', { name: /CONFIRM \(↵\)/i });
    fireEvent.click(confirmBtn);

    await waitFor(() => {
      expect(rpcModule.rpcAdminSetTeamValues).toHaveBeenCalledWith(
        expect.objectContaining({
          team_id: 'team-1',
          cash: 1200,
          expected_version: 1,
        })
      );
    });
  });

  it('blocks negative numbers in cash and CV input fields', () => {
    renderComponent();

    const cashInputs = screen.getAllByDisplayValue('1000');
    const cashInput = cashInputs[0];

    // Attempt to type negative symbol
    fireEvent.change(cashInput, { target: { value: '-500' } });
    // Non-digits are cleaned by handleInputChange -> '500'
    expect((cashInput as HTMLInputElement).value).toBe('500');
  });

  it('disables businesses owned by other teams in Add Business picker', async () => {
    renderComponent();

    // Click '+ ADD BUSINESS'
    const addBtn = screen.getByRole('button', { name: /\+ ADD BUSINESS/i });
    fireEvent.click(addBtn);

    await waitFor(() => {
      expect(screen.getByText(/ADD BUSINESS TO ALPHA ROCKETS/i)).toBeInTheDocument();
    });

    // EdTech is owned by Beta Builders -> button should be disabled with owned badge
    const edtechButton = screen.getByRole('button', { name: /EdTech/i });
    expect(edtechButton).toBeDisabled();
    expect(screen.getByText(/Owned by Beta Builders/i)).toBeInTheDocument();

    // FinTech is unowned -> should be enabled
    const fintechButton = screen.getByRole('button', { name: /FinTech/i });
    expect(fintechButton).not.toBeDisabled();
  });

  it('shows upgrade button for Level 0/1 businesses and hides it for Level 2 (max)', () => {
    renderComponent();

    // Team 1 (Alpha Rockets) owns SaaS at Level 0 -> should have Upgrade button
    expect(screen.getByRole('button', { name: /UPGRADE → L1/i })).toBeInTheDocument();

    // Select Team 2 (Beta Builders) which owns EdTech at Level 2
    const team2Card = screen.getByRole('button', { name: /Select team 2: Beta Builders/i });
    fireEvent.click(team2Card);

    // EdTech is at Level 2 -> should NOT have an UPGRADE button
    expect(screen.queryByRole('button', { name: /UPGRADE →/i })).not.toBeInTheDocument();
  });

  it('opens Remove Business dialog with Forced Sale default credit resale checked', async () => {
    renderComponent();

    const removeBtn = screen.getByRole('button', { name: 'REMOVE' });
    fireEvent.click(removeBtn);

    await waitFor(() => {
      expect(screen.getByText(/REMOVE SAAS/i)).toBeInTheDocument();
      expect(screen.getByText(/Forced Sale \(Rulebook debt relief\)/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/Credit resale value/i)).toBeChecked();
    });
  });

  it('displays ConflictDialog when VERSION_CONFLICT occurs and handles reload', async () => {
    const conflictErr = new Error('VERSION_CONFLICT');
    (conflictErr as any).code = 'VERSION_CONFLICT';
    (conflictErr as any).detail = {
      expected_version: 1,
      current_version: 2,
      cash: 1400,
      cv: 600,
    };
    vi.mocked(rpcModule.rpcAdminSetTeamValues).mockRejectedValue(conflictErr);

    const mockRefetch = vi.fn().mockResolvedValue(undefined);
    renderComponent({ onRefetch: mockRefetch });

    // Try to update cash
    const plus50Btn = screen.getAllByRole('button', { name: '+50' })[0];
    fireEvent.click(plus50Btn);
    fireEvent.click(screen.getAllByRole('button', { name: 'UPDATE' })[0]);
    fireEvent.click(screen.getByRole('button', { name: /CONFIRM/i }));

    // Conflict modal should appear
    await waitFor(() => {
      expect(screen.getByText(/TEAM CHANGED ELSEWHERE/i)).toBeInTheDocument();
      expect(screen.getByText(/v2/i)).toBeInTheDocument();
    });

    // Click 'RELOAD AND RETRY'
    const reloadBtn = screen.getByRole('button', { name: /RELOAD AND RETRY/i });
    fireEvent.click(reloadBtn);

    expect(mockRefetch).toHaveBeenCalled();
  });

  it('displays shortfall alert and action when INSUFFICIENT_CASH occurs', async () => {
    const cashErr = new Error('INSUFFICIENT_CASH');
    (cashErr as any).code = 'INSUFFICIENT_CASH';
    (cashErr as any).detail = {
      cash: 100,
      cost: 500,
      shortfall: 400,
    };
    vi.mocked(rpcModule.rpcAdminAddBusiness).mockRejectedValue(cashErr);

    renderComponent();

    // Open add business and select a business
    fireEvent.click(screen.getByRole('button', { name: /\+ ADD BUSINESS/i }));
    await waitFor(() => screen.getByRole('button', { name: /FinTech/i }));
    fireEvent.click(screen.getByRole('button', { name: /FinTech/i }));

    // Confirm acquisition
    fireEvent.click(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i }));

    // Shortfall banner should appear
    await waitFor(() => {
      expect(screen.getAllByText(/INSUFFICIENT CASH/i).length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText(/Shortfall of/i)).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /DO FORCED SALE FIRST/i })).toBeInTheDocument();
    });
  });

  it('requires note on confirm when room is in TIME_EXPIRED status', async () => {
    const expiredSnapshot: rpcModule.AdminRoomSnapshot = {
      ...mockSnapshot,
      room: {
        ...mockSnapshot.room,
        status: 'TIME_EXPIRED',
      },
    };

    renderComponent({ snapshot: expiredSnapshot });

    // Top banner shows game over
    expect(screen.getByText(/GAME OVER — scores frozen/i)).toBeInTheDocument();

    // Try to update cash
    const plus50Btn = screen.getAllByRole('button', { name: '+50' })[0];
    fireEvent.click(plus50Btn);
    fireEvent.click(screen.getAllByRole('button', { name: 'UPDATE' })[0]);

    // Confirm strip displays Note requirement
    await waitFor(() => {
      expect(screen.getByText(/NOTE REQUIRED/i)).toBeInTheDocument();
    });

    const confirmBtn = screen.getByRole('button', { name: /CONFIRM/i });
    expect(confirmBtn).toBeDisabled();

    // Type note
    const noteInput = screen.getByPlaceholderText(/Reason for post-game adjustment/i);
    fireEvent.change(noteInput, { target: { value: 'Late table count' } });

    expect(confirmBtn).not.toBeDisabled();
  });

  it('supports keyboard navigation using number keys 1-3 to select teams', () => {
    renderComponent();

    // Currently slot 1 is selected
    expect(screen.getByRole('heading', { name: /SLOT #1: Alpha Rockets/i })).toBeInTheDocument();

    // Press '2'
    fireEvent.keyDown(window, { key: '2' });

    // Now slot 2 is selected
    expect(screen.getByRole('heading', { name: /SLOT #2: Beta Builders/i })).toBeInTheDocument();
  });

  it('disables edit buttons and shows warning banner when connection is OFFLINE', () => {
    renderComponent({ connection: 'OFFLINE' });

    expect(screen.getByText(/OFFLINE — Edits disabled/i)).toBeInTheDocument();
    const updateButtons = screen.getAllByRole('button', { name: 'UPDATE' });
    expect(updateButtons[0]).toBeDisabled();
  });

  it('disables edit buttons and displays warning banner when scoreboard is stale >30s', () => {
    renderComponent({ isStale: true, staleAgeSeconds: 45 });

    expect(screen.getByText(/SCOREBOARD DATA IS STALE \(45s old\)/i)).toBeInTheDocument();
    const updateButtons = screen.getAllByRole('button', { name: 'UPDATE' });
    expect(updateButtons[0]).toBeDisabled();
  });

  it('manages abort modal with required note and triggers rpcAdminAbortGame', async () => {
    vi.mocked(rpcModule.rpcAdminAbortGame).mockResolvedValue({} as any);

    renderComponent();

    // Click abort button in top bar
    const abortBtn = screen.getByRole('button', { name: /ABORT GAME/i });
    fireEvent.click(abortBtn);

    // Modal opens
    expect(screen.getByText(/ABORT GAME — RETURN TO LOBBY/i)).toBeInTheDocument();
    expect(screen.getByText(/FULL TEAM RESET/i)).toBeInTheDocument();

    const confirmBtn = screen.getByRole('button', { name: /CONFIRM ABORT/i });
    expect(confirmBtn).toBeDisabled();

    // Type note
    const noteInput = screen.getByPlaceholderText(/Accidental start/i);
    fireEvent.change(noteInput, { target: { value: 'Accidental start by organizer' } });

    expect(confirmBtn).not.toBeDisabled();

    // Click confirm
    fireEvent.click(confirmBtn);

    await waitFor(() => {
      expect(rpcModule.rpcAdminAbortGame).toHaveBeenCalledWith('room-1', 'Accidental start by organizer');
    });
  });

  it('displays error in abort modal when rpcAdminAbortGame fails', async () => {
    vi.mocked(rpcModule.rpcAdminAbortGame).mockRejectedValue(new Error('NOTE_REQUIRED'));

    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /ABORT GAME/i }));

    const noteInput = screen.getByPlaceholderText(/Accidental start/i);
    fireEvent.change(noteInput, { target: { value: 'Accident' } });

    const confirmBtn = screen.getByRole('button', { name: /CONFIRM ABORT/i });
    fireEvent.click(confirmBtn);

    await waitFor(() => {
      expect(screen.getAllByText(/NOTE_REQUIRED/i).length).toBeGreaterThanOrEqual(1);
    });
  });

  it('allows aborting game when status is TIME_EXPIRED', async () => {
    vi.mocked(rpcModule.rpcAdminAbortGame).mockResolvedValue({} as any);

    renderComponent({
      snapshot: {
        ...mockSnapshot,
        room: {
          ...mockSnapshot.room,
          status: 'TIME_EXPIRED',
        },
      },
    });

    const abortBtn = screen.getByRole('button', { name: /ABORT GAME/i });
    expect(abortBtn).toBeInTheDocument();
    fireEvent.click(abortBtn);

    expect(screen.getByText(/ABORT GAME — RETURN TO LOBBY/i)).toBeInTheDocument();
    const noteInput = screen.getByPlaceholderText(/Accidental start/i);
    fireEvent.change(noteInput, { target: { value: 'Expired game restart' } });

    const confirmBtn = screen.getByRole('button', { name: /CONFIRM ABORT/i });
    fireEvent.click(confirmBtn);

    await waitFor(() => {
      expect(rpcModule.rpcAdminAbortGame).toHaveBeenCalledWith('room-1', 'Expired game restart');
    });
  });
});
