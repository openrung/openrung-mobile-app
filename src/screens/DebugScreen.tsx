/**
 * Debug console screen. 1:1 port of the production OpenRungDebugScreen:
 * header row, flex-1 console panel with "> line" entries and the last error
 * as "! error", and the traffic-route footer. Additionally shows a dim
 * "[mock native module]" notice when the JS fallback simulator is active.
 */
import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ConsolePanel } from '../components/ConsolePanel';
import { ScreenHeader } from '../components/ScreenHeader';
import { useStrings } from '../i18n';
import { isMock } from '../native/OpenRungVpn';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette } from '../theme';

export interface DebugScreenProps {
  onBack: () => void;
}

export function DebugScreen({ onBack }: DebugScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { state, isConnected } = useVpnState();

  return (
    <View
      style={[
        styles.root,
        { paddingTop: insets.top + 20, paddingBottom: insets.bottom + 20 },
      ]}
    >
      <ScreenHeader title={s.debugTitle} onBack={onBack} />

      <ConsolePanel
        logLines={state.native.logLines}
        lastError={state.native.lastError}
        showMockNotice={isMock}
        style={styles.console}
      />

      <Text style={styles.footer}>
        {isConnected ? s.trafficRouteConnected : s.trafficRouteDisconnected}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
    paddingHorizontal: 20,
    gap: 16,
  },
  console: {
    flex: 1,
  },
  footer: {
    alignSelf: 'center',
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
  },
});
