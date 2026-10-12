export interface ErrorMeta {
  message: string;
  retryable: boolean;
}

export class AppError extends Error {
  readonly code: string;
  readonly detail: Record<string, unknown> | null;
  readonly retryable: boolean;

  constructor(code: string, message?: string, detail: Record<string, unknown> | null = null) {
    const meta = ERROR_MAP[code];
    super(message || meta?.message || `An error occurred: ${code}`);
    this.name = 'AppError';
    this.code = code;
    this.detail = detail;
    this.retryable = meta ? meta.retryable : code === 'UNKNOWN_ERROR' || code === 'NETWORK_ERROR';
  }
}

export const ERROR_MAP: Record<string, ErrorMeta> = {
  NOT_ADMIN: {
    message: 'Access denied: Admin credentials required.',
    retryable: false,
  },
  NOT_AUTHENTICATED: {
    message: 'Authentication session missing or expired. Please sign in or rejoin.',
    retryable: true,
  },
  ROOM_NOT_FOUND: {
    message: 'Match room not found or invalid room code.',
    retryable: false,
  },
  INVALID_TRANSITION: {
    message: 'Invalid room status transition requested.',
    retryable: false,
  },
  ROOM_NOT_EDITABLE: {
    message: 'Edits are not permitted in the current room status.',
    retryable: false,
  },
  VERSION_CONFLICT: {
    message: 'Team values were modified elsewhere. Please refresh and retry.',
    retryable: true,
  },
  INVALID_VALUE: {
    message: 'Invalid input value provided.',
    retryable: false,
  },
  INSUFFICIENT_CASH: {
    message: 'Insufficient cash: Team cannot afford this transaction without a forced sale.',
    retryable: false,
  },
  BUSINESS_CAP: {
    message: 'Business cap reached: Teams can own at most 3 businesses.',
    retryable: false,
  },
  BUSINESS_OWNED: {
    message: 'Business already owned: This business is currently owned by another team.',
    retryable: false,
  },
  BUSINESS_NOT_FOUND: {
    message: 'Business key not recognized in business catalog.',
    retryable: false,
  },
  BUSINESS_NOT_OWNED: {
    message: 'Team does not own this business.',
    retryable: false,
  },
  ALREADY_MAX_LEVEL: {
    message: 'Business is already at maximum upgrade level (Level 2).',
    retryable: false,
  },
  CANNOT_UPGRADE_ZERO_LEVEL: {
    message: 'Business must be owned before upgrading.',
    retryable: false,
  },
  TEAM_BANKRUPT: {
    message: 'Action rejected: Team is bankrupt.',
    retryable: false,
  },
  UNRESOLVED_TIE: {
    message: 'Tiebreak required: Teams share identical metrics. Set tiebreak order first.',
    retryable: false,
  },
  TEAM_ALREADY_CLAIMED: {
    message: 'This team is already connected on another phone. Ask the organiser to release it before rejoining.',
    retryable: false,
  },
  BAD_CODE_OR_PIN: {
    message: 'Invalid match code, team slot, or 4-digit PIN.',
    retryable: true,
  },
  TOO_MANY_ATTEMPTS: {
    message: 'Too many failed join attempts. Please wait 60 seconds before retrying.',
    retryable: true,
  },
  NON_FINAL_ROOM_EXISTS: {
    message: 'Another active match room exists. Finalize it before creating a new match.',
    retryable: false,
  },
  NETWORK_ERROR: {
    message: 'Network communication failure. Please check your connection.',
    retryable: true,
  },
};

export function parseRpcError(err: unknown): AppError {
  if (err instanceof AppError) {
    return err;
  }

  if (typeof err === 'object' && err !== null) {
    const pgErr = err as { message?: string; code?: string; details?: string; hint?: string };
    const rawMsg = pgErr.message || '';
    let detail: Record<string, unknown> | null = null;

    if (pgErr.details) {
      try {
        detail = JSON.parse(pgErr.details);
      } catch {
        detail = { raw: pgErr.details };
      }
    }

    if (rawMsg in ERROR_MAP) {
      return new AppError(rawMsg, ERROR_MAP[rawMsg].message, detail);
    }

    return new AppError(
      pgErr.code || 'UNKNOWN_ERROR',
      rawMsg || 'An unexpected error occurred. Please try again.',
      detail
    );
  }

  return new AppError(
    'UNKNOWN_ERROR',
    err ? String(err) : 'An unexpected error occurred. Please try again.'
  );
}

export function isNetworkError(err: unknown): boolean {
  if (!err) return false;
  if (err instanceof AppError && err.code === 'NETWORK_ERROR') return true;
  const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
  return (
    msg.includes('failed to fetch') ||
    msg.includes('network') ||
    msg.includes('load failed') ||
    msg.includes('timeout') ||
    msg.includes('connection refused') ||
    msg.includes('econnrefused') ||
    msg.includes('offline')
  );
}

export function isBusinessError(err: unknown): boolean {
  if (err instanceof AppError) {
    // Known business codes are explicitly non-network domain violations
    return err.code in ERROR_MAP && err.code !== 'NETWORK_ERROR';
  }
  return false;
}

