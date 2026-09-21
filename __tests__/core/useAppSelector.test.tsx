import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { Text } from 'react-native';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import {
  type AppState,
  resetStoreForTests,
  setHomeViewMode,
  useAppSelector,
} from '../../src/state/store';

beforeEach(() => resetStoreForTests());

it('reselects when component props change without a store update', async () => {
  function Selected({ field }: { field: 'languageTag' | 'homeViewMode' }) {
    const value = useAppSelector(state => state[field]);
    return <Text>{value}</Text>;
  }
  let tree!: ReactTestRenderer.ReactTestRenderer;
  try {
    await act(async () => { tree = ReactTestRenderer.create(<Selected field="homeViewMode" />); });
    expect(tree.root.findByType(Text).props.children).toBe('map');
    await act(async () => { tree.update(<Selected field="languageTag" />); });
    expect(tree.root.findByType(Text).props.children).toBe('');
  } finally {
    await act(async () => { tree.unmount(); });
  }
});

it('reselects when the equality function changes', async () => {
  const selector = (state: AppState) => state.homeViewMode;
  const alwaysEqual = () => true;
  function Selected({ equal }: { equal: (a: string, b: string) => boolean }) {
    const value = useAppSelector(selector, equal);
    return <Text>{value}</Text>;
  }
  let tree!: ReactTestRenderer.ReactTestRenderer;
  try {
    await act(async () => { tree = ReactTestRenderer.create(<Selected equal={alwaysEqual} />); });
    await act(async () => { setHomeViewMode('list'); });
    expect(tree.root.findByType(Text).props.children).toBe('map');
    await act(async () => { tree.update(<Selected equal={Object.is} />); });
    expect(tree.root.findByType(Text).props.children).toBe('list');
  } finally {
    await act(async () => { tree.unmount(); });
  }
});

it('preserves equal selections and avoids renders for unrelated store changes', async () => {
  let renders = 0;
  function Selected() {
    const value = useAppSelector(state => ({ language: state.languageTag }));
    renders += 1;
    return <Text>{value.language}</Text>;
  }
  let tree!: ReactTestRenderer.ReactTestRenderer;
  try {
    await act(async () => { tree = ReactTestRenderer.create(<Selected />); });
    const initialRenders = renders;
    await act(async () => { setHomeViewMode('list'); });
    expect(renders).toBe(initialRenders);
  } finally {
    await act(async () => { tree.unmount(); });
  }
});
