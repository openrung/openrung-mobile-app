/**
 * Per-app split tunneling (Android only). Lists installed apps with a search
 * filter, a three-way mode selector, and per-app checkboxes; a sticky APPLY
 * button (shown only when the config is dirty) persists the change natively and,
 * when the tunnel is up, confirms the reconnect it triggers.
 *
 * Screen-local state, not the global store — nothing else in the app reads it
 * (same choice as the speed-test row). Config persistence lives natively (the
 * VpnService reads it at establish time), so there is no AsyncStorage mirror.
 */
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  FlatList,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { CheckIcon } from '../components/Icons';
import { RunButton } from '../components/RunButton';
import { ScreenHeader } from '../components/ScreenHeader';
import { ToggleSwitch } from '../components/ToggleSwitch';
import { useStrings, type Strings } from '../i18n';
import { OpenRungVpn } from '../native/OpenRungVpn';
import type { InstalledApp, SplitTunnelMode } from '../native/types';
import { useVpnState } from '../state/useVpnState';
import { monoFont, palette, tokens } from '../theme';

export interface SplitTunnelScreenProps {
  onBack: () => void;
}

const MODES: Array<{ mode: SplitTunnelMode; label: (s: Strings) => string; hint: (s: Strings) => string }> = [
  { mode: 'off', label: s => s.splitTunnelModeOff, hint: s => s.splitTunnelModeOffHint },
  { mode: 'proxyOnly', label: s => s.splitTunnelModeAllow, hint: s => s.splitTunnelModeAllowHint },
  { mode: 'bypass', label: s => s.splitTunnelModeDeny, hint: s => s.splitTunnelModeDenyHint },
];

export function SplitTunnelScreen({ onBack }: SplitTunnelScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();
  const { isConnected, prepareAndConnect, state } = useVpnState();

  const [apps, setApps] = useState<InstalledApp[] | null>(null);
  const [mode, setMode] = useState<SplitTunnelMode>('off');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [query, setQuery] = useState('');
  const [showSystem, setShowSystem] = useState(false);
  const [saving, setSaving] = useState(false);
  const [confirmReconnect, setConfirmReconnect] = useState(false);
  // The persisted baseline, to detect a dirty config.
  const [savedMode, setSavedMode] = useState<SplitTunnelMode>('off');
  const [savedPackages, setSavedPackages] = useState<string[]>([]);

  useEffect(() => {
    let mounted = true;
    Promise.all([OpenRungVpn.getInstalledApps(), OpenRungVpn.getSplitTunnelConfig()])
      .then(([installed, config]) => {
        if (!mounted) {
          return;
        }
        setApps(installed);
        setMode(config.mode);
        setSelected(new Set(config.packages));
        setSavedMode(config.mode);
        setSavedPackages(config.packages);
      })
      .catch(() => {
        if (mounted) {
          setApps([]);
        }
      });
    return () => {
      mounted = false;
    };
  }, []);

  const filtered = useMemo(() => {
    const list = apps ?? [];
    const needle = query.trim().toLowerCase();
    return list.filter(app => {
      if (!showSystem && app.isSystem) {
        return false;
      }
      if (needle.length === 0) {
        return true;
      }
      return (
        app.label.toLowerCase().includes(needle) ||
        app.packageName.toLowerCase().includes(needle)
      );
    });
  }, [apps, query, showSystem]);

  const dirty =
    mode !== savedMode ||
    selected.size !== savedPackages.length ||
    savedPackages.some(pkg => !selected.has(pkg));

  const toggleApp = useCallback((packageName: string) => {
    setSelected(current => {
      const next = new Set(current);
      if (next.has(packageName)) {
        next.delete(packageName);
      } else {
        next.add(packageName);
      }
      return next;
    });
  }, []);

  const persist = useCallback(async () => {
    setSaving(true);
    const config = { mode, packages: mode === 'off' ? [] : [...selected] };
    try {
      const { needsReconnect } = await OpenRungVpn.setSplitTunnelConfig(config);
      setSavedMode(config.mode);
      setSavedPackages(config.packages);
      if (needsReconnect) {
        // Re-establish so the new rules take effect on the current exit.
        prepareAndConnect(state.lastExitCountry).catch(() => {});
      }
    } catch {
      // Best-effort; the row stays dirty so the user can retry.
    } finally {
      setSaving(false);
    }
  }, [mode, selected, prepareAndConnect, state.lastExitCountry]);

  const onApply = useCallback(() => {
    if (isConnected) {
      setConfirmReconnect(true);
    } else {
      persist();
    }
  }, [isConnected, persist]);

  const activeHint = MODES.find(m => m.mode === mode)?.hint(s) ?? '';
  const selectionEnabled = mode !== 'off';

  return (
    <View style={[styles.root, { paddingTop: insets.top + 20 }]}>
      <ScreenHeader title={s.splitTunnelScreenTitle} onBack={onBack} />

      <View style={styles.modeRow}>
        {MODES.map(option => {
          const active = option.mode === mode;
          return (
            <Pressable
              key={option.mode}
              onPress={() => setMode(option.mode)}
              style={[styles.modeSegment, active && styles.modeSegmentActive]}
              accessibilityRole="button"
              accessibilityState={{ selected: active }}
            >
              <Text style={[styles.modeLabel, active && styles.modeLabelActive]}>
                {option.label(s)}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <Text style={styles.modeHint}>{activeHint}</Text>

      <TextInput
        style={[styles.search, !selectionEnabled && styles.searchDisabled]}
        placeholder={s.splitTunnelSearchPlaceholder}
        placeholderTextColor={palette.dimText}
        value={query}
        onChangeText={setQuery}
        editable={selectionEnabled}
        autoCapitalize="none"
        autoCorrect={false}
      />

      <View style={styles.systemToggleRow}>
        <Text style={styles.systemToggleLabel}>{s.splitTunnelShowSystem}</Text>
        <ToggleSwitch
          value={showSystem}
          onValueChange={setShowSystem}
          accessibilityLabel={s.splitTunnelShowSystem}
        />
      </View>

      {apps == null ? (
        <Text style={styles.loading}>{s.splitTunnelLoading}</Text>
      ) : (
        <FlatList
          style={styles.list}
          data={filtered}
          keyExtractor={item => item.packageName}
          getItemLayout={(_, index) => ({ length: ROW_HEIGHT, offset: ROW_HEIGHT * index, index })}
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={{ paddingBottom: tokens.tabBarHeight + insets.bottom + 80 }}
          renderItem={({ item }) => {
            const checked = selected.has(item.packageName);
            return (
              <Pressable
                onPress={() => toggleApp(item.packageName)}
                disabled={!selectionEnabled}
                style={[styles.appRow, !selectionEnabled && styles.appRowDisabled]}
                accessibilityRole="checkbox"
                accessibilityState={{ checked }}
              >
                <View style={styles.appText}>
                  <Text style={styles.appLabel} numberOfLines={1}>
                    {item.label}
                  </Text>
                  <Text style={styles.appPackage} numberOfLines={1}>
                    {item.packageName}
                  </Text>
                </View>
                <CheckIcon
                  color={checked ? palette.terminalGreen : palette.dimText}
                  size={22}
                  filled={checked}
                />
              </Pressable>
            );
          }}
        />
      )}

      {dirty ? (
        <View style={[styles.footer, { paddingBottom: insets.bottom + 16 }]}>
          <RunButton label={s.splitTunnelApply} onPress={onApply} enabled={!saving} />
        </View>
      ) : null}

      <Modal
        visible={confirmReconnect}
        transparent
        animationType="none"
        onRequestClose={() => setConfirmReconnect(false)}
      >
        <Pressable style={styles.modalBackdrop} onPress={() => setConfirmReconnect(false)}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>{s.splitTunnelReconnectTitle}</Text>
            <Text style={styles.modalBody}>{s.splitTunnelReconnectBody}</Text>
            <View style={styles.modalActions}>
              <Pressable onPress={() => setConfirmReconnect(false)} style={styles.modalButton}>
                <Text style={styles.modalButtonLabel}>{s.splitTunnelReconnectCancel}</Text>
              </Pressable>
              <Pressable
                onPress={() => {
                  setConfirmReconnect(false);
                  persist();
                }}
                style={styles.modalButton}
              >
                <Text style={styles.modalButtonLabel}>{s.splitTunnelReconnectConfirm}</Text>
              </Pressable>
            </View>
          </View>
        </Pressable>
      </Modal>
    </View>
  );
}

const ROW_HEIGHT = 60;

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
    paddingHorizontal: 20,
    gap: 12,
  },
  modeRow: {
    flexDirection: 'row',
    borderRadius: tokens.radiusSm,
    borderWidth: 1,
    borderColor: palette.borderDim,
    overflow: 'hidden',
  },
  modeSegment: {
    flex: 1,
    paddingVertical: 10,
    alignItems: 'center',
    backgroundColor: palette.panel,
  },
  modeSegmentActive: {
    backgroundColor: palette.fabBackground,
  },
  modeLabel: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    fontWeight: 'bold',
    letterSpacing: 0.5,
  },
  modeLabelActive: {
    color: palette.terminalGreen,
  },
  modeHint: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    lineHeight: 16,
  },
  search: {
    borderRadius: tokens.radiusSm,
    borderWidth: 1,
    borderColor: palette.borderDim,
    backgroundColor: palette.panel,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 13,
  },
  searchDisabled: {
    opacity: 0.4,
  },
  systemToggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  systemToggleLabel: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 12,
  },
  loading: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 13,
    marginTop: 20,
  },
  list: {
    flex: 1,
  },
  appRow: {
    height: ROW_HEIGHT,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: palette.borderDim,
  },
  appRowDisabled: {
    opacity: 0.4,
  },
  appText: {
    flex: 1,
    gap: 2,
  },
  appLabel: {
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 14,
  },
  appPackage: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
  },
  footer: {
    position: 'absolute',
    left: 20,
    right: 20,
    bottom: 0,
    paddingTop: 12,
    alignItems: 'center',
    backgroundColor: palette.screen,
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  modalCard: {
    minWidth: 280,
    maxWidth: 340,
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
    gap: 6,
    marginTop: 4,
  },
  modalButton: {
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  modalButtonLabel: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontSize: 12,
    fontWeight: 'bold',
    letterSpacing: 1,
  },
});
