import { BackHandler, Platform } from 'react-native';

type KeyListener = (event: { key: string }) => void;

interface KeyEventTarget {
  addEventListener(type: 'keyup', listener: KeyListener): void;
  removeEventListener(type: 'keyup', listener: KeyListener): void;
  querySelector(selector: string): unknown;
}

/** An open modal dialog, as react-native-web's Modal marks itself while it is active. */
const OPEN_MODAL_SELECTOR = '[role="dialog"][aria-modal="true"]';

/**
 * Subscribes to the platform's "go back" gesture: the hardware/system back button on mobile, the
 * Escape key in the desktop client. `handler` returns true when it consumed the press. Returns an
 * unsubscribe function.
 *
 * A visible Modal owns the gesture instead. On Android the system hands the back press to the
 * Modal (`onRequestClose`) rather than to BackHandler; in the desktop client react-native-web's
 * Modal closes itself on the Escape keyup, so that same keyup must not also reach `handler` and
 * move the route underneath the dialog.
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
  // keyup, not keydown: it is the event the Modal acts on, and it does not repeat while held.
  const onKeyUp: KeyListener = event => {
    if (event.key === 'Escape' && target.querySelector(OPEN_MODAL_SELECTOR) == null) {
      handler();
    }
  };
  target.addEventListener('keyup', onKeyUp);
  return () => target.removeEventListener('keyup', onKeyUp);
}
