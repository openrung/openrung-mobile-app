import { BackHandler, Platform } from 'react-native';

interface KeyEventTarget {
  addEventListener(type: 'keydown', listener: (event: { key: string }) => void): void;
  removeEventListener(type: 'keydown', listener: (event: { key: string }) => void): void;
}

/**
 * Subscribes to the platform's "go back" gesture: the hardware/system back button on mobile, the
 * Escape key in the desktop client. `handler` returns true when it consumed the press. Returns an
 * unsubscribe function.
 */
export function subscribeBackPress(handler: () => boolean): () => void {
  if (Platform.OS !== 'web') {
    const subscription = BackHandler.addEventListener('hardwareBackPress', handler);
    return () => subscription.remove();
  }
  const target = (globalThis as { document?: KeyEventTarget }).document;
  if (target == null) {
    return () => {};
  }
  const onKeyDown = (event: { key: string }) => {
    if (event.key === 'Escape') {
      handler();
    }
  };
  target.addEventListener('keydown', onKeyDown);
  return () => target.removeEventListener('keydown', onKeyDown);
}
