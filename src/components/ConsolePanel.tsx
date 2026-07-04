/**
 * Debug console panel. Mirrors the production Compose ConsolePanel: an
 * 8dp-rounded #07110B box with a 1dp #294F35 border and 14dp padding holding a
 * scrollable column of "> line" entries (terminal green, 13/18), the ready
 * placeholder when empty, and the last error appended as "! error" in #FFA0A0
 * after an 8dp spacer.
 */
import React from 'react';
import { ScrollView, StyleSheet, StyleProp, Text, View, ViewStyle } from 'react-native';

import { useStrings } from '../i18n';
import { monoFont, palette } from '../theme';

export interface ConsolePanelProps {
  logLines: string[];
  lastError: string | null;
  /** Shows a dim "[mock native module]" notice (Debug screen, mock fallback). */
  showMockNotice?: boolean;
  style?: StyleProp<ViewStyle>;
}

export function ConsolePanel({
  logLines,
  lastError,
  showMockNotice = false,
  style,
}: ConsolePanelProps): React.JSX.Element {
  const s = useStrings();
  const lines = logLines.length > 0 ? logLines : [s.readyLog];

  return (
    <View style={[styles.panel, style]}>
      <ScrollView style={styles.scroll} contentContainerStyle={styles.content}>
        {showMockNotice ? <Text style={styles.mockNotice}>[mock native module]</Text> : null}
        {lines.map((line, index) => (
          <Text key={`${index}-${line}`} style={styles.logLine}>
            {s.logLineFormat(line)}
          </Text>
        ))}
        {lastError != null ? (
          <>
            <View style={styles.errorSpacer} />
            <Text style={styles.errorLine}>{s.errorLineFormat(lastError)}</Text>
          </>
        ) : null}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  panel: {
    backgroundColor: palette.panel,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 14,
  },
  scroll: {
    flex: 1,
  },
  content: {
    gap: 6,
  },
  mockNotice: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
  },
  logLine: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 13,
    lineHeight: 18,
  },
  errorSpacer: {
    height: 8,
  },
  errorLine: {
    color: palette.consoleError,
    fontFamily: monoFont,
    fontSize: 13,
    lineHeight: 18,
  },
});
