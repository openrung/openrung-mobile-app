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
  settingsContentDescription: 'Open settings',
  settingsTitle: 'Settings',
  backContentDescription: 'Back',
  openContentDescription: 'Open',
  languageSettingTitle: 'Language',
  languageSettingSubtitle: 'Use system language or choose one for OpenRung.',
  versionSettingTitle: 'Version',
  speedTestSettingTitle: 'Volunteer speed test',
  speedTestReady: 'Download 10 MB through the active volunteer relay and report the result.',
  speedTestRequiresConnection: 'Connect to a volunteer relay before running the speed test.',
  speedTestRunning: 'Testing download speed through the volunteer relay…',
  speedTestResult: (mbps: number) => `Download speed: ${mbps.toFixed(1)} Mbps`,
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
  recentsLabel: 'Recents',
  recentsEmpty: 'No recent locations yet.',
  debugSettingTitle: 'Debug',
  debugSettingSubtitle: 'Connection console and diagnostics.',
  debugTitle: 'Debug console',
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
  settingsDiagnosticsHeader: 'Diagnostics',
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
