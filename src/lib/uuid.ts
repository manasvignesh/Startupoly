/**
 * Generates an RFC4122 version 4 compliant UUID.
 *
 * In secure contexts (HTTPS or localhost), uses native `crypto.randomUUID()`.
 * In non-secure contexts (such as plain HTTP across LAN mobile devices `http://192.168.x.x`),
 * browsers disable `crypto.randomUUID()`. This function provides a robust RFC4122 v4
 * fallback using `crypto.getRandomValues()` if available, or `Math.random()`.
 */
export function safeRandomUUID(): string {
  if (
    typeof crypto !== 'undefined' &&
    typeof crypto.randomUUID === 'function'
  ) {
    return crypto.randomUUID();
  }

  // Fallback using crypto.getRandomValues if available
  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    // RFC4122 v4 bits: set version to 4 (0100) and variant to 10xxxxxx
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  // Fallback using Math.random
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
