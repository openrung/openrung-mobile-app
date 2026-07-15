import { NativeModules, Platform } from 'react-native';

interface OpenRungApkShareModule {
  shareApk(chooserTitle: string): Promise<void>;
}

const nativeModule = (NativeModules as Record<string, unknown>)
  .OpenRungApkShare as OpenRungApkShareModule | null | undefined;

/** The action is intentionally Android-only and requires a binary with the native module linked. */
export const isApkShareAvailable =
  Platform.OS === 'android' && nativeModule != null;

export async function shareInstalledApk(chooserTitle: string): Promise<void> {
  if (!isApkShareAvailable || nativeModule == null) {
    const error = new Error(
      'offline APK sharing is unavailable on this platform',
    ) as Error & {
      code?: string;
    };
    error.code = 'E_SHARE_UNAVAILABLE';
    throw error;
  }
  await nativeModule.shareApk(chooserTitle);
}

export function apkShareErrorCode(error: unknown): string | null {
  if (typeof error !== 'object' || error == null || !('code' in error)) {
    return null;
  }
  const code = (error as { code?: unknown }).code;
  return typeof code === 'string' ? code : null;
}
