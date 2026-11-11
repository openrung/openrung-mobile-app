import { NativeModules, Platform } from 'react-native';

interface OpenRungWidgetModule {
  setLanguageTag(tag: string): Promise<void>;
}

const nativeModule = (NativeModules as Record<string, unknown>)
  .OpenRungWidget as OpenRungWidgetModule | null | undefined;

/**
 * iOS only: the home-screen widget renders in the in-app language, so the stored selection
 * ('' = system default) is mirrored to the app group under the widget's own key (contract §3).
 * A no-op on Android, in Jest, and on an iOS binary without the module.
 */
export function publishWidgetLanguage(tag: string): void {
  if (Platform.OS !== 'ios' || nativeModule == null) {
    return;
  }
  nativeModule.setLanguageTag(tag).catch(() => {
    // Best-effort, like the AsyncStorage persistence it mirrors.
  });
}
