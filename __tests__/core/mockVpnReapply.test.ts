/**
 * MockOpenRungVpn split-tunnel reapply: production tears down and reconnects to
 * the SAME target, re-stamping the same relay identity on the new CONNECTED —
 * the mock must not come back connected with the relay name/class lost.
 */
import { MockOpenRungVpn } from '../../src/native/mock';
import type { NativeVpnState } from '../../src/native/types';

const CONFIG_A = '{"version":1,"enabled":true}';
const CONFIG_B = '{"version":1,"enabled":false}';

async function flushScript(): Promise<void> {
  // Each scripted step schedules a plain setTimeout; run them all (steps never
  // schedule follow-up steps, so two passes are plenty).
  await Promise.resolve();
  jest.runAllTimers();
  await Promise.resolve();
  jest.runAllTimers();
}

beforeEach(() => {
  jest.useFakeTimers();
});

afterEach(() => {
  jest.useRealTimers();
});

describe('MockOpenRungVpn split-tunnel reapply', () => {
  it('keeps the connected relay identity across the reconnect walk', async () => {
    const mock = new MockOpenRungVpn();
    const states: NativeVpnState[] = [];
    mock.subscribe(state => states.push(state));

    await mock.connect('https://broker.example', null, null);
    await mock.setSplitTunnelConfig(CONFIG_A); // not connected yet: stores, no reconnect
    await flushScript();

    let state = await mock.getState();
    expect(state.status).toBe('connected');
    const { relayName, relayClass } = state;
    expect(relayName).not.toBeNull();
    expect(relayClass).not.toBeNull();

    states.length = 0;
    await mock.setSplitTunnelConfig(CONFIG_B); // changed while connected -> reapply walk
    // The brief reconnect is visible (connecting clears the identity, like native)…
    expect(states.some(s => s.status === 'connecting' && s.relayClass === null)).toBe(true);
    await flushScript();

    // …but the re-stamped CONNECTED restores the same relay name and class.
    state = await mock.getState();
    expect(state.status).toBe('connected');
    expect(state.relayName).toBe(relayName);
    expect(state.relayClass).toBe(relayClass);
  });

  it('is a no-op for an unchanged config (no reconnect walk at all)', async () => {
    const mock = new MockOpenRungVpn();
    await mock.connect('https://broker.example', null, null);
    await flushScript();
    await mock.setSplitTunnelConfig(CONFIG_A); // first push while connected: legit reapply
    await flushScript();

    const states: NativeVpnState[] = [];
    mock.subscribe(state => states.push(state));
    await mock.setSplitTunnelConfig(CONFIG_A); // string-equal: must not bounce the tunnel
    await flushScript();

    expect(states.every(s => s.status === 'connected')).toBe(true);
    const after = await mock.getState();
    expect(after.relayName).not.toBeNull();
    expect(after.relayClass).not.toBeNull();
  });
});
