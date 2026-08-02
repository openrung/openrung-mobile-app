import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import { Text } from 'react-native';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import { RelayClassBadge } from '../../src/components/RelayClassBadge';
import { LanguageProvider } from '../../src/i18n';
import { resetStoreForTests, setLanguageTag } from '../../src/state/store';

async function renderBadgeText(
  nodeClass: 'foundation' | 'volunteer',
  languageTag: string,
): Promise<string[]> {
  let tree: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    setLanguageTag(languageTag);
    tree = ReactTestRenderer.create(
      <LanguageProvider>
        <RelayClassBadge nodeClass={nodeClass} />
      </LanguageProvider>,
    );
  });
  const texts = tree!.root
    .findAllByType(Text)
    .flatMap(node => node.props.children)
    .filter((value): value is string => typeof value === 'string');
  await ReactTestRenderer.act(async () => {
    tree!.unmount();
  });
  return texts;
}

beforeEach(() => {
  resetStoreForTests();
});

describe('RelayClassBadge', () => {
  it('renders the upcased class labels in English', async () => {
    expect(await renderBadgeText('foundation', 'en')).toEqual(['OFFICIAL']);
    expect(await renderBadgeText('volunteer', 'en')).toEqual(['VOLUNTEER']);
  });

  it('uppercases with the active locale (Turkish dotted i -> İ, never RESMI)', async () => {
    expect(await renderBadgeText('foundation', 'tr')).toEqual(['RESMİ']);
  });
});
