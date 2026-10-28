import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { StyleSheet, Text } from 'react-native';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import { ConnectCard } from '../../src/components/ConnectCard';
import type { ConnectCardProps } from '../../src/components/ConnectCard';

async function renderTexts(props: Partial<ConnectCardProps> = {}): Promise<string[]> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    tree = ReactTestRenderer.create(
      <ConnectCard
        status="connected"
        relayName="proud-falcon"
        relayClass={null}
        isConnected
        isWorking={false}
        onToggle={jest.fn()}
        {...props}
      />,
    );
  });
  const text = tree!.root
    .findAllByType(Text)
    .flatMap(node => node.props.children)
    .filter((value): value is string => typeof value === 'string');
  await ReactTestRenderer.act(async () => {
    tree!.unmount();
  });
  return text;
}

describe('ConnectCard', () => {
  it('shows the connected relay name without a traffic-route footer', async () => {
    const text = await renderTexts();
    expect(text).toContain('proud-falcon');
    expect(text).not.toContain('traffic route: device -> OpenRung VPN -> relay');
  });

  it('shows the relay-class badge while connected: foundation renders OFFICIAL', async () => {
    const text = await renderTexts({ relayClass: 'foundation' });
    expect(text).toContain('proud-falcon');
    expect(text).toContain('OFFICIAL');
    expect(text).not.toContain('VOLUNTEER');
  });

  it('shows the relay-class badge while connected: volunteer renders VOLUNTEER', async () => {
    const text = await renderTexts({ relayClass: 'volunteer' });
    expect(text).toContain('VOLUNTEER');
    expect(text).not.toContain('OFFICIAL');
  });

  it('renders no badge when the class is unknown (stale native build)', async () => {
    const text = await renderTexts({ relayClass: null });
    expect(text).not.toContain('OFFICIAL');
    expect(text).not.toContain('VOLUNTEER');
  });

  it('renders no badge while disconnected even if a class is passed', async () => {
    const text = await renderTexts({
      status: 'disconnected',
      relayName: null,
      relayClass: 'volunteer',
      isConnected: false,
    });
    expect(text).not.toContain('VOLUNTEER');
  });

  it('re-stretches the fill disc when the button is resized (window resize)', async () => {
    const baseProps: ConnectCardProps = {
      status: 'disconnected',
      relayName: null,
      relayClass: null,
      isConnected: false,
      isWorking: false,
      onToggle: jest.fn(),
    };
    let tree: ReactTestRenderer.ReactTestRenderer | undefined;
    await ReactTestRenderer.act(async () => {
      tree = ReactTestRenderer.create(<ConnectCard {...baseProps} />);
    });
    const button = tree!.root.findAll(node => typeof node.props.onLayout === 'function')[0];
    const layout = (width: number, height: number) =>
      ReactTestRenderer.act(async () => {
        button.props.onLayout({ nativeEvent: { layout: { x: 0, y: 0, width, height } } });
      });
    const discRadius = (): number => {
      const disc = tree!.root.findAll(node => {
        const style = StyleSheet.flatten(node.props.style) as { borderRadius?: number; left?: number };
        return style?.borderRadius != null && style.left != null && node.props.pointerEvents === 'none';
      })[0];
      return (StyleSheet.flatten(disc.props.style) as { borderRadius: number }).borderRadius;
    };

    await layout(300, 56);
    // Connect without a tap: the disc grows from the button center.
    await ReactTestRenderer.act(async () => {
      tree!.update(<ConnectCard {...baseProps} status="connecting" isWorking />);
    });
    const narrow = discRadius();
    expect(narrow).toBeCloseTo(Math.hypot(150, 28), 3);

    // Widen the window: the anchor stays, the radius reaches the new far corner.
    await layout(480, 56);
    expect(discRadius()).toBeCloseTo(Math.hypot(330, 28), 3);
    expect(discRadius()).toBeGreaterThan(narrow);

    await ReactTestRenderer.act(async () => {
      tree!.unmount();
    });
  });
});
