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
  readyLog: 'ready. tap connect to route through a relay.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'traffic route: device -> OpenRung VPN -> relay',
  trafficRouteDisconnected: 'vpn is fail-closed: no relay, no connection.',
  settingsContentDescription: 'Open settings',
  settingsTitle: 'Settings',
  backContentDescription: 'Back',
  openContentDescription: 'Open',
  languageSettingTitle: 'Language',
  languageSettingSubtitle: 'Use system language or choose one for OpenRung.',
  versionSettingTitle: 'Version',
  speedTestSettingTitle: 'Relay speed test',
  speedTestReady: 'Download 10 MB through the active relay and report the result.',
  speedTestRequiresConnection: 'Connect to a relay before running the speed test.',
  speedTestRunning: 'Testing download speed through the relay…',
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
  mapContentDescription: 'Map of available exit nodes across the Asia-Pacific region',
  mapLoading: 'locating available exit nodes…',
  mapFailed: "couldn't load exit nodes — tap to retry",
  mapNodesAvailable: (count: number) => `${count} locations available`,
  mapNoNodes: 'no exit nodes available right now',
  recentsLabel: 'Recents',
  recentsEmpty: 'No recent locations yet.',
  viewToggleMap: 'Map',
  viewToggleList: 'List',
  listContentDescription: 'List of available exit nodes',
  listRelayCount: (count: number) => (count === 1 ? '1 relay' : `${count} relays`),
  debugSettingTitle: 'Debug',
  debugSettingSubtitle: 'Connection console and diagnostics.',
  debugTitle: 'Debug console',
  licensesSettingTitle: 'Open-source licenses',
  licensesSettingSubtitle: 'Licenses and attribution for bundled software.',
  licensesTitle: 'Open-source licenses',
  licensesIntro:
    'OpenRung is free software licensed under GPL-3.0-or-later because it links sing-box. The complete corresponding source for this build is available at the link below.',
  licensesSourceTitle: 'Source code',
  privacyPolicyTitle: 'Privacy policy',
  privacyPolicySubtitle: 'How OpenRung handles beta diagnostics and personal information.',
  licensesFullTextTitle: 'Full license texts',
  licensesFullTextSubtitle: 'GNU GPL-3.0 and third-party notices.',
  licensesComponentsHeader: 'Components',
  shareApkTitle: 'Share OpenRung offline',
  shareApkSubtitle: 'Send this APK to a nearby Android phone without internet.',
  shareApkErrorTitle: 'Unable to share OpenRung',
  shareApkErrorBody:
    'The APK could not be shared. Keep OpenRung open and try again.',
  shareApkSplitInstallError:
    'This copy was installed as multiple APK files and cannot be shared safely. Install the standalone OpenRung APK to use offline sharing.',
  shareTestFlightTitle: 'Share OpenRung',
  shareTestFlightSubtitle: 'Send a TestFlight link that installs the iOS beta.',
  shareTestFlightMessage: 'Join the OpenRung beta on TestFlight:',
  shareTestFlightErrorTitle: 'Unable to share OpenRung',
  shareTestFlightErrorBody: 'The TestFlight link could not be shared. Try again.',

  // --- Redesigned shell (tabs, home overlay, about) ---
  tabHome: 'Home',
  tabSettings: 'Settings',
  tabAbout: 'About us',
  homeTagline: 'relay network',
  relayAuto: 'auto relay',
  settingsGeneralHeader: 'General',
  settingsDiagnosticsHeader: 'Diagnostics',
  aboutTitle: 'About us',
  aboutMissionBody:
    'OpenRung routes your traffic through relays around the world, keeping the open internet reachable when networks are filtered. No account is required and there are no ads. During early testing, OpenRung collects diagnostic connection metadata to improve reliability.',
  aboutHowHeader: 'How it works',
  aboutProjectHeader: 'Project',
  aboutHow1Title: 'Relay operators provide capacity',
  aboutHow1Body:
    'The OpenRung Foundation and community volunteers run relays and register them with the network.',
  aboutHow2Title: 'The broker finds your relay',
  aboutHow2Body:
    'When you connect, the broker hands your device a short list of healthy relays and the app picks the first one that answers.',
  aboutHow3Title: 'Traffic rides an encrypted tunnel',
  aboutHow3Body:
    'Everything flows through a VLESS/REALITY tunnel that looks like ordinary TLS, and the VPN is fail-closed: no relay, no traffic.',
  aboutFootnote:
    'OpenRung is free software (GPL-3.0-or-later). Built by volunteers, for everyone.',

  // --- Ocean telemetry panel (map view, anchored over the Pacific) ---
  telemetryNetworkHeader: 'NETWORK',
  telemetryLinkHeader: 'LINK',
  telemetryRelaysLabel: 'relays',
  telemetryLocationsLabel: 'locations',
  telemetryCountriesLabel: 'countries',
  telemetryUptimeLabel: 'uptime',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'Update required',
  updateRequiredBody:
    'This version of OpenRung can no longer connect to the relay network. Install the latest release to keep going.',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: 'UPDATE',
  updateActionLater: 'Later',
  updateContinueAnyway: 'Continue anyway',
  updateBannerTitle: 'Update available',
  updateBannerBody: (latest: string) =>
    `Version ${latest} includes important fixes. Update when you can.`,
  updateSettingTitle: 'Update available',
  updateSettingSubtitle: (current: string, latest: string) =>
    `You have v${current}; v${latest} is out. Tap to get it.`,
  noticeDismiss: 'Dismiss',
  noticeLearnMore: 'Learn more',
};

export type Strings = typeof en;
