import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { PropertySoldModal } from './PropertySoldModal';
import { PropertySoldEvent } from '../../data/broadcast';

describe('PropertySoldModal', () => {
  const mockEvent: PropertySoldEvent = {
    teamName: 'Alpha Rockets',
    teamColor: '#E52521',
    businessKey: 'fintech',
    businessName: 'FinTech',
    cost: 400,
    timestamp: Date.now(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders nothing when event is null', () => {
    const { container } = render(<PropertySoldModal event={null} onDismiss={vi.fn()} />);
    expect(container.firstChild).toBeNull();
  });

  it('renders the Title Deed card details, announcement, and SOLD badge', () => {
    render(<PropertySoldModal event={mockEvent} onDismiss={vi.fn()} />);

    expect(screen.getByText(/STARTUPOLY TITLE DEED/i)).toBeInTheDocument();
    expect(screen.getByText('FinTech')).toBeInTheDocument();
    expect(screen.getByText(/ALPHA ROCKETS BOUGHT THIS!/i)).toBeInTheDocument();
    expect(screen.getByText(/Purchase Price: ₹400/i)).toBeInTheDocument();
    expect(screen.getByText('SOLD!')).toBeInTheDocument();
    expect(screen.getByText(/Base Rent/i)).toBeInTheDocument();
    expect(screen.getByText('₹200')).toBeInTheDocument();
  });

  it('calls onDismiss when dismiss button is clicked', () => {
    const onDismiss = vi.fn();
    render(<PropertySoldModal event={mockEvent} onDismiss={onDismiss} />);

    fireEvent.click(screen.getByText(/\[ TAP TO DISMISS \]/i));
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it('auto-dismisses after duration', () => {
    vi.useFakeTimers();
    const onDismiss = vi.fn();
    render(<PropertySoldModal event={mockEvent} onDismiss={onDismiss} />);

    expect(onDismiss).not.toHaveBeenCalled();

    // Fast-forward past 6000ms
    act(() => {
      vi.advanceTimersByTime(6100);
    });

    expect(onDismiss).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });
});
