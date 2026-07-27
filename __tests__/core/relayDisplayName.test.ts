/**
 * sanitizeRelayName / relayDisplayName: operator-supplied relay labels rendered
 * safe for the UI (RelayList rows and their accessibility labels). Mirrors the
 * native Kotlin/Swift `RelayDescriptor.displayName()` sanitizers — the three
 * rule sets must stay in sync (control/format strip, Zs/Zl/Zp collapse,
 * 24-code-point clamp, id fallback).
 */
import { relayDisplayName, sanitizeRelayName } from '../../src/model/exitNode';

describe('sanitizeRelayName', () => {
  it('passes ordinary labels through trimmed', () => {
    expect(sanitizeRelayName('  proud-falcon  ')).toBe('proud-falcon');
  });

  it('strips control characters', () => {
    expect(sanitizeRelayName('proud\u{7}fal\u{1B}con')).toBe('proudfalcon');
  });

  it('strips bidi override and other format characters', () => {
    // U+202E RIGHT-TO-LEFT OVERRIDE could reorder surrounding UI text.
    expect(sanitizeRelayName('\u{202E}npj.yaler')).toBe('npj.yaler');
    expect(sanitizeRelayName('proud\u{200B}\u{200D}falcon')).toBe('proudfalcon');
  });

  it('strips astral-plane format characters', () => {
    // U+E0061 TAG LATIN SMALL LETTER A (plane 14) encodes hidden text.
    expect(sanitizeRelayName('proud\u{E0061}falcon')).toBe('proudfalcon');
  });

  it('collapses unicode space-separator runs', () => {
    expect(sanitizeRelayName('proud   falcon')).toBe('proud falcon');
    // NBSP and ideographic space are Zs, line/paragraph separators Zl/Zp.
    expect(sanitizeRelayName('proud\u{A0}\u{3000}falcon')).toBe('proud falcon');
    expect(sanitizeRelayName('proud\u{2028}\u{2029}falcon')).toBe('proud falcon');
  });

  it('clamps to 24 code points, never splitting a surrogate pair', () => {
    expect(sanitizeRelayName('x'.repeat(80))).toBe('x'.repeat(24));
    // 30 rockets = 60 UTF-16 units; the clamp counts code points like Kotlin/Swift.
    expect(sanitizeRelayName('\u{1F680}'.repeat(30))).toBe('\u{1F680}'.repeat(24));
    expect(sanitizeRelayName('x'.repeat(23) + '\u{1F680}rocket')).toBe(
      'x'.repeat(23) + '\u{1F680}',
    );
  });

  it('returns empty when nothing printable remains', () => {
    expect(sanitizeRelayName('\u{202E}\u{200B}\u{7}')).toBe('');
  });
});

describe('relayDisplayName', () => {
  it('uses the sanitized label when present', () => {
    expect(relayDisplayName({ id: 'relay_jp1', label: ' proud-falcon ' })).toBe('proud-falcon');
  });

  it('falls back to the shortened id when the label is null or unprintable', () => {
    expect(relayDisplayName({ id: 'relay_abcdef1234567890', label: null })).toBe('abcdef123456');
    expect(relayDisplayName({ id: 'relay_jp1', label: '\u{202E}\u{200B}' })).toBe('jp1');
  });
});
