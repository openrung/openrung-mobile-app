import { NativeModules, Platform } from 'react-native';

/**
 * Mirrors the in-app language override into the iOS app group so the home-screen widget
 * can use the same strings. Android has no widget here; a missing native module is a no-op.
 * The value is a language tag or '' for the system locale. It is not a secret.
 */
export function publishWidgetLanguage(tag: string): void {
  if (Platform.OS !== 'ios') {
    return;
  }
  const widget = (
    NativeModules as {
      OpenRungWidget?: { setLanguageTag?: (languageTag: string) => void };
    }
  ).OpenRungWidget;
  widget?.setLanguageTag?.(tag);
}
