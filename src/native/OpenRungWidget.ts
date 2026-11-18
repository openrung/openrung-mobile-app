import { NativeModules } from 'react-native';

interface OpenRungWidgetModule {
  setLanguageTag(tag: string): Promise<void>;
}

const nativeModule = (NativeModules as Record<string, unknown>)
  .OpenRungWidget as OpenRungWidgetModule | null | undefined;

/**
 * The home-screen widget renders in the in-app language, so the stored selection ('' = system
 * default) is mirrored to native (contract §3): the iOS app group, or Android's widget preferences.
 * A no-op in Jest and on a binary without the module.
 */
export function publishWidgetLanguage(tag: string): void {
  if (nativeModule == null) {
    return;
  }
  nativeModule.setLanguageTag(tag).catch(() => {
    // Best-effort, like the AsyncStorage persistence it mirrors.
  });
}
