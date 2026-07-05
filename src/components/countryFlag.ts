/**
 * ISO 3166-1 alpha-2 -> flag emoji via regional indicators; neutral flag for
 * anything that is not two ASCII letters. Shared by the recents pills and the
 * relay-list rows.
 */
export function countryFlag(code: string): string {
  const upper = code.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(upper)) {
    return '🏳';
  }
  const first = 0x1f1e6 + (upper.charCodeAt(0) - 65);
  const second = 0x1f1e6 + (upper.charCodeAt(1) - 65);
  return String.fromCodePoint(first) + String.fromCodePoint(second);
}
