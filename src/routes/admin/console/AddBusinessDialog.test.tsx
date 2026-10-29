import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { AddBusinessDialog } from './AddBusinessDialog';
import type { AdminRoomSnapshot } from '../../../data/rpc';

type Team = AdminRoomSnapshot['teams'][number];

const team = (over: Partial<Team> = {}): Team => ({
  id: 'team-1', slot: 1, name: 'Alpha Rockets', color: '#E52521', cash: 1000, debt: 0, board_position: 0,
  is_bankrupt: false, version: 1, tiebreak_order: null, claimed: true, businesses: [], ...over,
});

const owned = (key: string, name: string) => ({ business_key: key, name, level: 0, cost: 200 });

describe('AddBusinessDialog', () => {
  it('needs a note for a manual (free) entry and not for a normal purchase', () => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    const t = team();
    render(<AddBusinessDialog isOpen onClose={vi.fn()} team={t} allTeams={[t]} onSubmit={onSubmit} isTimeExpired={false} />);

    fireEvent.click(screen.getByText('EdTech'));
    expect(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i })).not.toBeDisabled();

    fireEvent.click(screen.getByLabelText(/Apply purchase/i));
    expect(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i })).toBeDisabled();
    expect(screen.getByText(/NOTE REQUIRED \(MANUAL ENTRY\)/i)).toBeInTheDocument();

    fireEvent.change(screen.getByPlaceholderText(/Physical auction purchase/i), { target: { value: 'board dispute' } });
    expect(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i })).not.toBeDisabled();
  });

  it('blocks a third business: the cap is 2', () => {
    const t = team({ businesses: [owned('edtech', 'EdTech'), owned('saas', 'SaaS')] });
    render(<AddBusinessDialog isOpen onClose={vi.fn()} team={t} allTeams={[t]} onSubmit={vi.fn()} isTimeExpired={false} />);
    expect(screen.getByText(/business cap \(2\/2\)/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i })).toBeDisabled();
  });

  it('restricts options to only the landed property when team lands on a business space', () => {
    // board_position: 1 is AI / DeepTech (cost 500)
    const t = team({ board_position: 1 });
    render(<AddBusinessDialog isOpen onClose={vi.fn()} team={t} allTeams={[t]} onSubmit={vi.fn()} isTimeExpired={false} />);

    expect(screen.getByText(/LANDED ON: AI \/ DEEPTECH/i)).toBeInTheDocument();
    expect(screen.getByText('AI / DeepTech')).toBeInTheDocument();
    // EdTech and SaaS should NOT be in the restricted list
    expect(screen.queryByText('EdTech')).toBeNull();
    expect(screen.queryByText('SaaS')).toBeNull();
    // Pre-selected and enabled to purchase immediately
    expect(screen.getByRole('button', { name: /CONFIRM ACQUISITION/i })).not.toBeDisabled();
  });
});
