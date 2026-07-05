/**
 * English strings — the source of truth, ported from the production
 * `android/app/src/main/res/values/strings.xml` (declared en-US). Other locales override a subset
 * and fall back to these values for any missing key.
 *
 * Pure-native notification/service-log resources (vpn_notification_*, log_*, error_*) are not
 * ported: the native layer emits those already-localized inside `logLines` / `lastError`.
 */
export const en = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `status = ${status}`,
  relayFormat: (relay: string) => `relay = ${relay}`,
  relayLocationUnknown: 'Unknown location',
  actionConnect: 'CONNECT',
  actionDisconnect: 'DISCONNECT',
  readyLog: 'ready. tap connect to route through a volunteer relay.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'traffic route: device -> OpenRung VPN -> volunteer relay',
  trafficRouteDisconnected: 'vpn is fail-closed: no relay, no connection.',
  trafficStatsAccessibility: (down: string, up: string) => `Download ${down}, upload ${up}`,
  settingsContentDescription: 'Open settings',
  settingsTitle: 'Settings',
  backContentDescription: 'Back',
  openContentDescription: 'Open',
  languageSettingTitle: 'Language',
  languageSettingSubtitle: 'Use system language or choose one for OpenRung.',
  versionSettingTitle: 'Version',
  speedTestSettingTitle: 'Volunteer speed test',
  speedTestReady:
    'Measure download and upload speed through the active volunteer relay (10 MB each way).',
  speedTestRequiresConnection: 'Connect to a volunteer relay before running the speed test.',
  speedTestRunning: 'Testing download speed through the volunteer relay…',
  speedTestRunningUpload: 'Testing upload speed through the volunteer relay…',
  speedTestResult: (mbps: number) => `Download speed: ${mbps.toFixed(1)} Mbps`,
  speedTestResultBoth: (down: number, up: number) =>
    `↓ ${down.toFixed(1)} Mbps   ↑ ${up.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `Speed test failed: ${error}`,
  speedTestAction: 'RUN',
  languageSystem: 'System default',
  languageEnglish: 'English',
  languageSimplifiedChinese: 'Simplified Chinese',
  languageTraditionalChinese: 'Traditional Chinese',
  languagePersian: 'Persian',
  languageRussian: 'Russian',
  languageArabic: 'Arabic',
  languageTurkish: 'Turkish',
  languageVietnamese: 'Vietnamese',
  languageBurmese: 'Burmese',
  statusDisconnected: 'Disconnected',
  statusPreparing: 'Preparing VPN',
  statusConnecting: 'Connecting',
  statusConnected: 'Connected',
  statusDisconnecting: 'Disconnecting',
  statusFailed: 'Failed',
  mapContentDescription: 'Map of available volunteer exit nodes across the Asia-Pacific region',
  mapLoading: 'locating available exit nodes…',
  mapFailed: "couldn't load exit nodes — tap to retry",
  mapNodesAvailable: (count: number) => `${count} locations available`,
  mapNoNodes: 'no exit nodes available right now',

  // --- Latency test / connect-to-fastest ---
  latencyTestAction: 'test latency',
  latencyTesting: 'pinging relays…',
  latencyBest: (label: string, ms: number) => `best: ${label} ${ms}ms`,
  latencyFailed: 'latency test failed — tap to retry',
  latencyStale: 'results stale — tap to re-test',
  latencyAgeJustNow: 'just now',
  latencyAgeMinutes: (m: number) => `${m}m ago`,
  latencyUnreachable: 'unreachable',
  latencyViaTunnelNote: 'disconnect to measure the direct path',
  actionConnectFastest: 'FASTEST',
  fastestFinding: 'finding fastest exit…',
  fastestNoResults: 'no reachable exits — connecting via broker pick',
  recentsLabel: 'Recents',
  recentsEmpty: 'No recent locations yet.',
  favoritesLabel: 'Favorites',
  favoriteAddContentDescription: 'Add to favorites',
  favoriteRemoveContentDescription: 'Remove from favorites',
  locationConnectContentDescription: (label: string) => `Connect to ${label}`,
  debugSettingTitle: 'Debug',
  debugSettingSubtitle: 'Connection console and diagnostics.',
  debugTitle: 'Debug console',
  debugShowLiveLog: 'LIVE',
  debugShowFullLog: 'FULL LOG',
  debugShareAction: 'SHARE',
  debugClearAction: 'CLEAR',
  debugShareNotice:
    'persisted log is scrubbed (no addresses or credentials) but includes timestamps and connection events.',
  debugPersistedEmpty: 'no persisted log yet.',
  debugClearConfirmTitle: 'Clear persisted log?',
  debugClearConfirmBody: 'This deletes the on-device runtime log used for bug reports.',
  debugClearConfirmYes: 'CLEAR',
  debugClearConfirmNo: 'CANCEL',
  licensesSettingTitle: 'Open-source licenses',
  licensesSettingSubtitle: 'Licenses and attribution for bundled software.',
  licensesTitle: 'Open-source licenses',
  licensesIntro:
    'OpenRung is free software licensed under GPL-3.0-or-later because it links sing-box. The complete corresponding source for this build is available at the link below.',
  licensesSourceTitle: 'Source code',
  licensesFullTextTitle: 'Full license texts',
  licensesFullTextSubtitle: 'GNU GPL-3.0 and third-party notices.',
  licensesComponentsHeader: 'Components',

  // --- Redesigned shell (tabs, home overlay, about) ---
  tabHome: 'Home',
  tabSettings: 'Settings',
  tabAbout: 'About us',
  homeTagline: 'volunteer relay network',
  relayAuto: 'auto relay',
  settingsGeneralHeader: 'General',
  settingsConnectionHeader: 'Connection',
  settingsDiagnosticsHeader: 'Diagnostics',
  settingsToolboxHeader: 'Network toolbox',

  // --- Connection preferences ---
  autoConnectTitle: 'Auto-connect on launch',
  autoConnectSubtitle: 'Start the tunnel automatically when the app opens.',
  rememberExitTitle: 'Remember last exit',
  rememberExitSubtitle: 'Auto-connect returns to your last exit location.',

  // --- Exit IP check ---
  exitIpTitle: 'Exit IP check',
  exitIpReady:
    'Show the public IP your traffic exits from. Contacts a third-party lookup service.',
  exitIpRequiresConnection:
    'Connect first — checking while disconnected would reveal your real IP.',
  exitIpRunning: 'Checking exit IP through the tunnel…',
  exitIpResult: (ip: string, detail: string) => (detail ? `${ip} — ${detail}` : ip),
  exitIpError: (error: string) => `Exit IP check failed: ${error}`,
  exitIpAction: 'CHECK',

  // --- Network toolbox ---
  toolboxSubtitle: 'Opens a third-party site in your browser (outside the app).',
  toolboxIpCheck: 'IP address check',
  toolboxDnsLeak: 'DNS leak test',
  toolboxWebrtcLeak: 'WebRTC leak test',
  toolboxSpeedTest: 'Web speed test',

  // --- Per-app split tunneling (Android only) ---
  splitTunnelTitle: 'Per-app VPN',
  splitTunnelSubtitleOff: 'All apps use the VPN.',
  splitTunnelSubtitleAllow: (n: number) => `${n} app${n === 1 ? '' : 's'} use the VPN.`,
  splitTunnelSubtitleDeny: (n: number) => `${n} app${n === 1 ? '' : 's'} bypass the VPN.`,
  splitTunnelScreenTitle: 'Per-app VPN',
  splitTunnelModeOff: 'Off',
  splitTunnelModeAllow: 'Only selected',
  splitTunnelModeDeny: 'Bypass selected',
  splitTunnelModeOffHint: 'Every app routes through the VPN.',
  splitTunnelModeAllowHint: 'Only the checked apps route through the VPN; everything else goes direct.',
  splitTunnelModeDenyHint: 'The checked apps go direct; everything else routes through the VPN.',
  splitTunnelSearchPlaceholder: 'Search apps…',
  splitTunnelShowSystem: 'Show system apps',
  splitTunnelApply: 'APPLY',
  splitTunnelLoading: 'loading apps…',
  splitTunnelReconnectTitle: 'Reconnect to apply?',
  splitTunnelReconnectBody: 'Changing per-app rules restarts the active tunnel.',
  splitTunnelReconnectConfirm: 'APPLY & RECONNECT',
  splitTunnelReconnectCancel: 'CANCEL',
  aboutTitle: 'About us',
  aboutMissionBody:
    'OpenRung routes your traffic through relays run by volunteers around the world, keeping the open internet reachable when networks are filtered. No accounts, no ads, no tracking — just people sharing bandwidth.',
  aboutHowHeader: 'How it works',
  aboutProjectHeader: 'Project',
  aboutHow1Title: 'Volunteers share bandwidth',
  aboutHow1Body:
    'People everywhere run small relay nodes on their own connections and register them with the network.',
  aboutHow2Title: 'The broker finds your relay',
  aboutHow2Body:
    'When you connect, the broker hands your device a short list of healthy relays and the app picks the first one that answers.',
  aboutHow3Title: 'Traffic rides an encrypted tunnel',
  aboutHow3Body:
    'Everything flows through a VLESS/REALITY tunnel that looks like ordinary TLS, and the VPN is fail-closed: no relay, no traffic.',
  aboutFootnote:
    'OpenRung is free software (GPL-3.0-or-later). Built by volunteers, for everyone.',
};

export type Strings = typeof en;
