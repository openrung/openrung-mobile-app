// Web entry for the claude.ai/design sync (design-sync skill). Curated
// re-exports of the web-renderable components — the native-only ExitNodeMap
// (MapLibre map view) and NativeTabs (native tab host) are deliberately
// excluded. Bundled with react-native aliased to react-native-web via
// .design-sync/tsconfig.sync.json; see .design-sync/NOTES.md.

export { ConnectCard } from '../src/components/ConnectCard';
export type { ConnectCardProps } from '../src/components/ConnectCard';
export { ConsolePanel } from '../src/components/ConsolePanel';
export type { ConsolePanelProps } from '../src/components/ConsolePanel';
export { EdgeFade } from '../src/components/EdgeFade';
export {
  HomeIcon,
  InfoIcon,
  ListIcon,
  MapIcon,
  PowerIcon,
  SlidersIcon,
} from '../src/components/Icons';
export type { IconProps } from '../src/components/Icons';
export { MapStatusChip } from '../src/components/MapStatusChip';
export type { MapStatusChipProps } from '../src/components/MapStatusChip';
export { OceanTelemetry, formatUptime, lastDialledRelay } from '../src/components/OceanTelemetry';
export type { OceanTelemetryProps } from '../src/components/OceanTelemetry';
export { RecentsSection } from '../src/components/RecentsSection';
export type { RecentsSectionProps } from '../src/components/RecentsSection';
export { RelayList } from '../src/components/RelayList';
export type { RelayListProps } from '../src/components/RelayList';
export { ScreenHeader } from '../src/components/ScreenHeader';
export type { ScreenHeaderProps } from '../src/components/ScreenHeader';
export { SettingPanel } from '../src/components/SettingPanel';
export type { SettingPanelProps } from '../src/components/SettingPanel';
export { TabBar } from '../src/components/TabBar';
export type { AppTab, TabBarProps } from '../src/components/TabBar';
export { ViewModeToggle } from '../src/components/ViewModeToggle';
export type { ViewModeToggleProps } from '../src/components/ViewModeToggle';
export { countryFlag } from '../src/components/countryFlag';

// Theme: the exact production palette + product tokens (src/theme.ts).
export {
  monoFont,
  palette,
  statusDotColor,
  tokens,
} from '../src/theme';

// i18n helpers the components lean on (useStrings falls back to
// system-resolved strings without a provider — no wrapper needed).
export { LanguageProvider, languageOptions, statusLabel, stringsForTag, useLanguage, useStrings } from '../src/i18n';
export type { Strings } from '../src/i18n';

// Model helpers used when composing RelayList / OceanTelemetry data.
export { relayDisplayName } from '../src/model/exitNode';
export type { DirectoryStatus, ExitNodeRegion, ExitNodeRelay, HomeViewMode } from '../src/model/exitNode';
export type { ConnectionStatus, RecentNode } from '../src/native/types';
