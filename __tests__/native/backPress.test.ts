import { BackHandler, Platform } from 'react-native';

import { subscribeBackPress } from '../../src/native/backPress';

type KeyListener = (event: { key: string }) => void;

/** The slice of `document` the desktop client's back handling touches. */
class FakeDocument {
  /** What a query for an open modal dialog finds. */
  openModal: object | null = null;
  readonly queries: string[] = [];
  private readonly listeners = new Map<string, Set<KeyListener>>();

  addEventListener(type: string, listener: KeyListener): void {
    if (!this.listeners.has(type)) {
      this.listeners.set(type, new Set());
    }
    this.listeners.get(type)!.add(listener);
  }

  removeEventListener(type: string, listener: KeyListener): void {
    this.listeners.get(type)?.delete(listener);
  }

  querySelector(selector: string): object | null {
    this.queries.push(selector);
    return this.openModal;
  }

  /** A full key press, as the browser delivers it. */
  press(key: string): void {
    for (const type of ['keydown', 'keyup']) {
      this.listeners.get(type)?.forEach(listener => listener({ key }));
    }
  }
}

const originalOS = Platform.OS;
const globals = globalThis as { document?: unknown };

function setPlatform(os: string): void {
  Object.defineProperty(Platform, 'OS', { configurable: true, get: () => os });
}

afterEach(() => {
  setPlatform(originalOS);
  delete globals.document;
  jest.restoreAllMocks();
});

describe('subscribeBackPress on mobile', () => {
  it('subscribes to the hardware back button and removes the subscription', () => {
    const remove = jest.fn();
    const addEventListener = jest
      .spyOn(BackHandler, 'addEventListener')
      .mockReturnValue({ remove });
    const handler = jest.fn(() => true);

    const unsubscribe = subscribeBackPress(handler);
    expect(addEventListener).toHaveBeenCalledWith('hardwareBackPress', handler);
    unsubscribe();
    expect(remove).toHaveBeenCalledTimes(1);
  });
});

describe('subscribeBackPress in the desktop client', () => {
  let document: FakeDocument;

  beforeEach(() => {
    setPlatform('web');
    document = new FakeDocument();
    globals.document = document;
  });

  it('goes back once per Escape press and ignores other keys', () => {
    const handler = jest.fn(() => true);
    subscribeBackPress(handler);

    document.press('Enter');
    expect(handler).not.toHaveBeenCalled();
    document.press('Escape');
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('leaves Escape to an open modal instead of navigating behind it', () => {
    // Regression: with the language picker open, Escape both closed the picker and sent the
    // route from Settings back to Home.
    const handler = jest.fn(() => true);
    subscribeBackPress(handler);

    document.openModal = {};
    document.press('Escape');
    expect(handler).not.toHaveBeenCalled();
    // The query is for react-native-web's active Modal markup.
    expect(document.queries).toEqual(['[role="dialog"][aria-modal="true"]']);

    // Once the modal is gone, Escape navigates again.
    document.openModal = null;
    document.press('Escape');
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('stops listening after unsubscribe', () => {
    const handler = jest.fn(() => true);
    const unsubscribe = subscribeBackPress(handler);
    unsubscribe();
    document.press('Escape');
    expect(handler).not.toHaveBeenCalled();
  });

  it('does not touch the hardware back button', () => {
    const addEventListener = jest.spyOn(BackHandler, 'addEventListener');
    subscribeBackPress(() => true);
    expect(addEventListener).not.toHaveBeenCalled();
  });
});
