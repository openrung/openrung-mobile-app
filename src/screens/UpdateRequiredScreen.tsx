import React, { useCallback } from 'react';
import { Linking, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { APP_VERSION, AppConfig } from '../config';
import { useStrings } from '../i18n';
import { continueDespiteBlock } from '../state/updateCheck';
import { useAppState } from '../state/store';
import { monoFont, palette, tokens } from '../theme';

/**
 * Full-screen "Update required" gate, shown only when a VERIFIED manifest says this version is
 * below the supported floor (see model/updateStatus.ts). The update destination is always the
 * pinned AppConfig constant — never manifest-supplied. "Continue anyway" is the deliberate,
 * session-scoped escape hatch per the availability-first design: a user pointing the app at
 * their own broker may still work on an "unsupported" build, and informing beats bricking.
 */
export function UpdateRequiredScreen(): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { update } = useAppState();

  const onUpdate = useCallback(() => {
    const url = Platform.OS === 'ios' ? AppConfig.TESTFLIGHT_URL : AppConfig.UPDATE_URL_ANDROID;
    Linking.openURL(url).catch(() => {
      // Best-effort: ignore devices without a browser handler.
    });
  }, []);

  return (
    <View
      style={[
        styles.root,
        { paddingTop: insets.top + 24, paddingBottom: insets.bottom + 24 },
      ]}
    >
      <View style={styles.body}>
        <Text style={styles.title}>{s.updateRequiredTitle}</Text>
        <Text style={styles.message}>{s.updateRequiredBody}</Text>
        {update.latestVersion != null ? (
          <Text style={styles.versions}>
            {s.updateVersionTransition(APP_VERSION, update.latestVersion)}
          </Text>
        ) : null}
      </View>
      <View style={styles.footer}>
        <Pressable
          onPress={onUpdate}
          style={({ pressed }) => [styles.updateButton, pressed && styles.pressed]}
          accessibilityRole="button"
        >
          <Text style={styles.updateLabel}>{s.updateActionNow}</Text>
        </Pressable>
        <Pressable
          onPress={continueDespiteBlock}
          style={({ pressed }) => [styles.continueButton, pressed && styles.pressed]}
          accessibilityRole="button"
        >
          <Text style={styles.continueLabel}>{s.updateContinueAnyway}</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
    paddingHorizontal: tokens.edge,
  },
  body: {
    flex: 1,
    justifyContent: 'center',
    gap: 14,
  },
  title: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 24,
    letterSpacing: 0.5,
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 12,
  },
  message: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 14,
    lineHeight: 21,
  },
  versions: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  footer: {
    gap: 10,
  },
  updateButton: {
    height: 52,
    borderRadius: 26,
    backgroundColor: palette.terminalGreen,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: tokens.glow,
    shadowOpacity: 1,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 0 },
    elevation: 6,
  },
  updateLabel: {
    color: palette.onGreenText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 15,
    letterSpacing: 1,
  },
  continueButton: {
    alignItems: 'center',
    paddingVertical: 10,
  },
  continueLabel: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  pressed: {
    opacity: 0.85,
  },
});
