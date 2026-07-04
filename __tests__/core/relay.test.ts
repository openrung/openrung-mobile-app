import { isUsable, orderedCandidates, selectFirstUsable } from '../../src/model/relay';
import type { RelayDescriptor } from '../../src/model/relay';

const NOW_MS = Date.parse('2026-01-01T00:00:00Z');

function relay(overrides: Partial<RelayDescriptor> = {}): RelayDescriptor {
  return {
    id: 'relay-1',
    public_host: '203.0.113.10',
    public_port: 443,
    protocol: 'vless-reality-vision',
    client_id: 'e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f',
    reality_public_key: 'pubkey',
    short_id: 'abcd',
    server_name: 'www.example.com',
    flow: 'xtls-rprx-vision',
    exit_mode: 'direct',
    max_sessions: 8,
    max_mbps: 100,
    volunteer_version: '1.0.0',
    registered_at: '2025-12-31T00:00:00Z',
    last_heartbeat_at: '2025-12-31T23:59:00Z',
    expires_at: '2026-01-01T01:00:00Z',
    ...overrides,
  };
}

describe('isUsable', () => {
  it('accepts a fresh VLESS Reality Vision direct-exit relay', () => {
    expect(isUsable(relay(), NOW_MS)).toBe(true);
  });

  it('rejects an expired relay (expires_at <= server time)', () => {
    expect(isUsable(relay({ expires_at: '2025-12-31T23:59:59Z' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ expires_at: '2026-01-01T00:00:00Z' }), NOW_MS)).toBe(false);
  });

  it('rejects an unparseable expires_at', () => {
    expect(isUsable(relay({ expires_at: 'not-a-date' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ expires_at: '' }), NOW_MS)).toBe(false);
  });

  it('rejects the wrong protocol, flow, or exit mode', () => {
    expect(isUsable(relay({ protocol: 'vless' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ flow: '' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ exit_mode: 'relay' }), NOW_MS)).toBe(false);
  });

  it('rejects blank connection material', () => {
    expect(isUsable(relay({ public_host: '  ' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ public_port: 0 }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ client_id: '' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ reality_public_key: ' ' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ short_id: '' }), NOW_MS)).toBe(false);
    expect(isUsable(relay({ server_name: '' }), NOW_MS)).toBe(false);
  });
});

describe('relay selection', () => {
  it('filters to usable relays preserving broker order (no client-side scoring)', () => {
    const usableA = relay({ id: 'a' });
    const expired = relay({ id: 'b', expires_at: '2025-01-01T00:00:00Z' });
    const usableC = relay({ id: 'c' });
    expect(orderedCandidates([usableA, expired, usableC], NOW_MS).map(r => r.id)).toEqual([
      'a',
      'c',
    ]);
  });

  it('selectFirstUsable returns the first usable relay or null', () => {
    const expired = relay({ id: 'b', expires_at: '2025-01-01T00:00:00Z' });
    expect(selectFirstUsable([expired, relay({ id: 'c' })], NOW_MS)?.id).toBe('c');
    expect(selectFirstUsable([expired], NOW_MS)).toBeNull();
  });
});
