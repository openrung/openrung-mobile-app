/**
 * Debug console screen. Port of the production OpenRungDebugScreen (header
 * row, flex-1 console panel with "> line" entries and the last error as
 * "! error", traffic-route footer, dim "[mock native module]" notice when the
 * JS simulator is active) — extended with the persisted runtime log:
 *
 *  - LIVE shows the in-memory 80-line tail (as before);
 *  - FULL loads the scrubbed persisted log (survives restarts, cap ~1000);
 *  - SHARE exports the persisted log via the system share sheet;
 *  - CLEAR (with confirm) deletes the persisted log.
 */
import React, { useCallback, useEffect, useState } from 'react';
import { Modal, Pressable, Share, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ConsolePanel } from '../components/ConsolePanel';
import { ScreenHeader } from '../components/ScreenHeader';
import { useStrings } from '../i18n';
import { isMock, OpenRungVpn } from '../native/OpenRungVpn';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette, tokens } from '../theme';

export interface DebugScreenProps {
  onBack: () => void;
}

type LogView = 'live' | 'full';

export function DebugScreen({ onBack }: DebugScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { state, isConnected } = useVpnState();

  const [view, setView] = useState<LogView>('live');
  const [persisted, setPersisted] = useState<string[] | null>(null);
  const [confirmClear, setConfirmClear] = useState(false);

  const loadPersisted = useCallback(() => {
    OpenRungVpn.getPersistedLog()
      .then(setPersisted)
      .catch(() => setPersisted([]));
  }, []);

  useEffect(() => {
    loadPersisted();
  }, [loadPersisted]);

  const onSelectView = useCallback(
    (next: LogView) => {
      setView(next);
      if (next === 'full') {
        loadPersisted(); // refresh so FULL shows lines appended since mount
      }
    },
    [loadPersisted],
  );

  const onShare = useCallback(() => {
    const lines = persisted ?? [];
    if (lines.length === 0) {
      return;
    }
    Share.share({ message: lines.join('\n') }).catch(() => {
      // User dismissed the sheet / no share targets — nothing to do.
    });
  }, [persisted]);

  const onConfirmClear = useCallback(() => {
    setConfirmClear(false);
    OpenRungVpn.clearPersistedLog()
      .then(loadPersisted)
      .catch(() => {});
  }, [loadPersisted]);

  const fullLines =
    persisted != null && persisted.length > 0 ? persisted : [s.debugPersistedEmpty];

  return (
    <View
      style={[
        styles.root,
        { paddingTop: insets.top + 20, paddingBottom: insets.bottom + 20 },
      ]}
    >
      <ScreenHeader title={s.debugTitle} onBack={onBack} />

      <View style={styles.toolbar}>
        <View style={styles.segments}>
          <SegmentButton
            label={s.debugShowLiveLog}
            active={view === 'live'}
            onPress={() => onSelectView('live')}
          />
          <SegmentButton
            label={s.debugShowFullLog}
            active={view === 'full'}
            onPress={() => onSelectView('full')}
          />
        </View>
        <View style={styles.actions}>
          <TextButton label={s.debugShareAction} onPress={onShare} />
          <TextButton label={s.debugClearAction} onPress={() => setConfirmClear(true)} />
        </View>
      </View>
      <Text style={styles.shareNotice}>{s.debugShareNotice}</Text>

      {view === 'live' ? (
        <ConsolePanel
          logLines={state.native.logLines}
          lastError={state.native.lastError}
          showMockNotice={isMock}
          style={styles.console}
        />
      ) : (
        <ConsolePanel
          logLines={fullLines}
          lastError={null}
          showMockNotice={isMock}
          style={styles.console}
        />
      )}

      <Text style={styles.footer}>
        {isConnected ? s.trafficRouteConnected : s.trafficRouteDisconnected}
      </Text>

      <Modal
        visible={confirmClear}
        transparent
        animationType="none"
        onRequestClose={() => setConfirmClear(false)}
      >
        <Pressable style={styles.modalBackdrop} onPress={() => setConfirmClear(false)}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>{s.debugClearConfirmTitle}</Text>
            <Text style={styles.modalBody}>{s.debugClearConfirmBody}</Text>
            <View style={styles.modalActions}>
              <TextButton label={s.debugClearConfirmNo} onPress={() => setConfirmClear(false)} />
              <TextButton label={s.debugClearConfirmYes} onPress={onConfirmClear} />
            </View>
          </View>
        </Pressable>
      </Modal>
    </View>
  );
}

function SegmentButton({
  label,
  active,
  onPress,
}: {
  label: string;
  active: boolean;
  onPress: () => void;
}): React.JSX.Element {
  return (
    <Pressable
      onPress={onPress}
      style={[styles.segment, active && styles.segmentActive]}
      accessibilityRole="button"
      accessibilityState={{ selected: active }}
    >
      <Text style={[styles.segmentLabel, active && styles.segmentLabelActive]}>{label}</Text>
    </Pressable>
  );
}

function TextButton({ label, onPress }: { label: string; onPress: () => void }): React.JSX.Element {
  return (
    <Pressable onPress={onPress} style={styles.textButton} accessibilityRole="button">
      <Text style={styles.textButtonLabel}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
    paddingHorizontal: 20,
    gap: 12,
  },
  toolbar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  segments: {
    flexDirection: 'row',
    borderRadius: tokens.radiusSm,
    borderWidth: 1,
    borderColor: palette.borderDim,
    overflow: 'hidden',
  },
  segment: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    backgroundColor: palette.panel,
  },
  segmentActive: {
    backgroundColor: palette.fabBackground,
  },
  segmentLabel: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    fontWeight: 'bold',
    letterSpacing: 1,
  },
  segmentLabelActive: {
    color: palette.terminalGreen,
  },
  actions: {
    flexDirection: 'row',
    gap: 4,
  },
  textButton: {
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  textButtonLabel: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 12,
    fontWeight: 'bold',
    letterSpacing: 1,
  },
  shareNotice: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 10,
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
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modalCard: {
    minWidth: 260,
    maxWidth: 320,
    borderRadius: tokens.radiusSm,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 18,
    gap: 10,
  },
  modalTitle: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
  },
  modalBody: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
    lineHeight: 17,
  },
  modalActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 8,
    marginTop: 4,
  },
});
