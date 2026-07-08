import type { Strings } from './en';

/** Ported from `res/values-zh-rTW/strings.xml`; missing keys fall back to English. */
export const zhTW: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `狀態 = ${status}`,
  relayFormat: (relay: string) => `中繼 = ${relay}`,
  relayLocationUnknown: '未知位置',
  actionConnect: '連線',
  actionDisconnect: '中斷連線',
  readyLog: '就緒。點選「連線」即可透過志工中繼路由。',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: '流量路徑：裝置 -> OpenRung VPN -> 志願者中繼',
  trafficRouteDisconnected: 'VPN 採用失敗關閉：沒有中繼，就不連線。',
  settingsContentDescription: '開啟設定',
  settingsTitle: '設定',
  backContentDescription: '返回',
  languageSettingTitle: '語言',
  languageSettingSubtitle: '使用系統語言，或為 OpenRung 選擇語言。',
  versionSettingTitle: '版本',
  languageSystem: '跟隨系統',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: '已中斷',
  statusPreparing: '正在準備 VPN',
  statusConnecting: '正在連線',
  statusConnected: '已連線',
  statusDisconnecting: '正在中斷',
  statusFailed: '失敗',

  // Redesigned shell (tabs / about / section headers).
  tabHome: '首頁',
  tabSettings: '設定',
  tabAbout: '關於我們',
  aboutTitle: '關於我們',
  relayAuto: '自動中繼',
  settingsGeneralHeader: '一般',
  settingsDiagnosticsHeader: '診斷',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: '網路',
  telemetryLinkHeader: '鏈路',
  telemetryRelaysLabel: '中繼',
  telemetryLocationsLabel: '地點',
  telemetryCountriesLabel: '國家',
  telemetryUptimeLabel: '連線時長',

  // Open control + volunteer speed test.
  openContentDescription: '開啟',
  speedTestSettingTitle: '志願者速度測試',
  speedTestReady: '透過使用中的志願者中繼下載 10 MB 並回報結果。',
  speedTestRequiresConnection: '執行速度測試前，請先連線至志願者中繼。',
  speedTestRunning: '正在透過志願者中繼測試下載速度…',
  speedTestResult: (mbps: number) => `下載速度：${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `速度測試失敗：${error}`,
  speedTestAction: '執行',

  // Map / list views.
  mapContentDescription: '橫跨亞太地區的可用志願者出口節點地圖',
  mapLoading: '正在尋找可用的出口節點…',
  mapFailed: '無法載入出口節點 — 點選以重試',
  mapNodesAvailable: (count: number) => `${count} 個地點可用`,
  mapNoNodes: '目前沒有可用的出口節點',
  recentsLabel: '最近使用',
  recentsEmpty: '尚無最近使用的地點。',
  viewToggleMap: '地圖',
  viewToggleList: '清單',
  listContentDescription: '可用志願者出口節點的清單',
  listRelayCount: (count: number) => (count === 1 ? '1 個中繼' : `${count} 個中繼`),

  // Debug console.
  debugSettingTitle: '除錯',
  debugSettingSubtitle: '連線主控台與診斷。',
  debugTitle: '除錯主控台',

  // Open-source licenses.
  licensesSettingTitle: '開放原始碼授權',
  licensesSettingSubtitle: '隨附軟體的授權與出處標示。',
  licensesTitle: '開放原始碼授權',
  licensesIntro:
    'OpenRung 是自由軟體；由於連結了 sing-box，因此依 GPL-3.0-or-later 授權。此版本的完整對應原始碼可透過下方連結取得。',
  licensesSourceTitle: '原始碼',
  licensesFullTextTitle: '完整授權條款全文',
  licensesFullTextSubtitle: 'GNU GPL-3.0 與第三方聲明。',
  licensesComponentsHeader: '元件',

  // Home tagline + about screen.
  homeTagline: '志願者中繼網路',
  aboutMissionBody:
    'OpenRung 會透過世界各地志願者營運的中繼路由你的流量，在網路遭到過濾時，仍讓開放的網際網路保持可連線。沒有帳號、沒有廣告、沒有追蹤 — 只有人們彼此分享頻寬。',
  aboutHowHeader: '運作方式',
  aboutProjectHeader: '專案',
  aboutHow1Title: '志願者分享頻寬',
  aboutHow1Body:
    '世界各地的人們會在自己的網路連線上架設小型中繼節點，並向網路註冊。',
  aboutHow2Title: '中介為你找到中繼',
  aboutHow2Body:
    '當你連線時，中介會將一份簡短的健康中繼清單交給你的裝置，而應用程式會挑選第一個有回應的中繼。',
  aboutHow3Title: '流量行經加密通道',
  aboutHow3Body:
    '一切都會流經看起來就像一般 TLS 的 VLESS/REALITY 通道，而 VPN 採用失敗關閉：沒有中繼，就沒有流量。',
  aboutFootnote:
    'OpenRung 是自由軟體（GPL-3.0-or-later）。由志願者打造，獻給每一個人。',
};
