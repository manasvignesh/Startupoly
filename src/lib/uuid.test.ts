import { describe, it, expect, afterEach } from 'vitest';
import { safeRandomUUID } from './uuid';

describe('safeRandomUUID', () => {
  const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

  it('generates a valid RFC4122 v4 UUID using default crypto environment', () => {
    const uuid = safeRandomUUID();
    expect(uuid).toMatch(UUID_V4_REGEX);
  });

  it('generates distinct UUIDs across multiple calls', () => {
    const set = new Set<string>();
    for (let i = 0; i < 100; i++) {
      set.add(safeRandomUUID());
    }
    expect(set.size).toBe(100);
  });

  describe('fallbacks for non-secure contexts (e.g. LAN HTTP)', () => {
    const originalCrypto = globalThis.crypto;

    afterEach(() => {
      Object.defineProperty(globalThis, 'crypto', {
        value: originalCrypto,
        writable: true,
        configurable: true,
      });
    });

    it('falls back to crypto.getRandomValues when crypto.randomUUID is undefined', () => {
      // Simulate non-secure context where crypto.randomUUID is absent but getRandomValues exists
      const mockCrypto = {
        getRandomValues: (arr: Uint8Array) => {
          for (let i = 0; i < arr.length; i++) {
            arr[i] = Math.floor(Math.random() * 256);
          }
          return arr;
        },
      };

      Object.defineProperty(globalThis, 'crypto', {
        value: mockCrypto,
        writable: true,
        configurable: true,
      });

      const uuid = safeRandomUUID();
      expect(uuid).toMatch(UUID_V4_REGEX);
    });

    it('falls back to Math.random when entire crypto object is unavailable', () => {
      Object.defineProperty(globalThis, 'crypto', {
        value: undefined,
        writable: true,
        configurable: true,
      });

      const uuid = safeRandomUUID();
      expect(uuid).toMatch(UUID_V4_REGEX);
    });
  });
});
