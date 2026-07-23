import { NativeModules, Platform } from 'react-native';

export interface InstalledApp {
  packageName: string;
  label: string;
}

interface OpenRungAppListModule {
  getInstalledApps(): Promise<InstalledApp[]>;
}

const nativeModule = (NativeModules as Record<string, unknown>)
  .OpenRungAppList as OpenRungAppListModule | null | undefined;

/** Per-app bypass is intentionally Android-only and requires a binary with the native module linked. */
export const isAppListAvailable =
  Platform.OS === 'android' && nativeModule != null;

/**
 * Installed launcher apps (deduped, sorted by label, our own package excluded — see
 * OpenRungAppListModule). Resolves [] on iOS or when the module is absent (Jest, fresh
 * Metro without a native rebuild), so callers never need a platform branch.
 */
export async function getInstalledApps(): Promise<InstalledApp[]> {
  if (!isAppListAvailable || nativeModule == null) {
    return [];
  }
  return nativeModule.getInstalledApps();
}
