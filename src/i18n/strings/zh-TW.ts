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
  readyLog: '就緒。點選「連線」即可透過中繼路由。',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: '流量路徑：裝置 -> OpenRung VPN -> 中繼',
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

  // Open control + relay speed test.
  openContentDescription: '開啟',
  speedTestSettingTitle: '中繼速度測試',
  speedTestReady: '透過使用中的中繼下載 10 MB 並回報結果。',
  speedTestRequiresConnection: '執行速度測試前，請先連線至中繼。',
  speedTestRunning: '正在透過中繼測試下載速度…',
  speedTestResult: (mbps: number) => `下載速度：${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `速度測試失敗：${error}`,
  speedTestAction: '執行',

  // Map / list views.
  mapContentDescription: '橫跨亞太地區的可用出口節點地圖',
  mapLoading: '正在尋找可用的出口節點…',
  mapFailed: '無法載入出口節點 — 點選以重試',
  mapNodesAvailable: (count: number) => `${count} 個地點可用`,
  mapNoNodes: '目前沒有可用的出口節點',
  recentsLabel: '最近使用',
  recentsEmpty: '尚無最近使用的地點。',
  viewToggleMap: '地圖',
  viewToggleList: '清單',
  listContentDescription: '可用出口節點的清單',
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
  privacyPolicyTitle: '隱私權政策',
  privacyPolicySubtitle: 'OpenRung 如何處理測試版診斷資料與個人資訊。',
  licensesFullTextTitle: '完整授權條款全文',
  licensesFullTextSubtitle: 'GNU GPL-3.0 與第三方聲明。',
  licensesComponentsHeader: '元件',
  shareApkTitle: '離線分享 OpenRung',
  shareApkSubtitle: '無需網際網路，將此 APK 傳送到附近的 Android 手機。',
  shareApkErrorTitle: '無法分享 OpenRung',
  shareApkErrorBody: '無法分享 APK。請保持 OpenRung 開啟並再試一次。',
  shareApkSplitInstallError:
    '此版本由多個 APK 檔案安裝，無法安全分享。請安裝 OpenRung 獨立 APK 後使用離線分享。',
  shareTestFlightTitle: '分享 OpenRung',
  shareTestFlightSubtitle: '傳送 TestFlight 連結，供他人安裝 iOS 測試版。',
  shareTestFlightMessage: '透過 TestFlight 加入 OpenRung 測試版：',
  shareTestFlightErrorTitle: '無法分享 OpenRung',
  shareTestFlightErrorBody: '無法分享 TestFlight 連結。請再試一次。',

  // Home tagline + about screen.
  homeTagline: '中繼網路',
  aboutMissionBody:
    'OpenRung 會透過世界各地的中繼路由你的流量，在網路遭到過濾時，仍讓開放的網際網路保持可連線。不需要帳號，也沒有廣告。在早期測試期間，OpenRung 會收集診斷性的連線中繼資料，以提升可靠性。',
  aboutHowHeader: '運作方式',
  aboutProjectHeader: '專案',
  aboutHow1Title: '中繼營運者提供網路容量',
  aboutHow1Body:
    'OpenRung 基金會與社群志願者營運中繼，並向網路註冊。',
  aboutHow2Title: '中介為你找到中繼',
  aboutHow2Body:
    '當你連線時，中介會將一份簡短的健康中繼清單交給你的裝置，而應用程式會挑選第一個有回應的中繼。',
  aboutHow3Title: '流量行經加密通道',
  aboutHow3Body:
    '一切都會流經看起來就像一般 TLS 的 VLESS/REALITY 通道，而 VPN 採用失敗關閉：沒有中繼，就沒有流量。',
  aboutFootnote:
    'OpenRung 是自由軟體（GPL-3.0-or-later）。由志願者打造，獻給每一個人。',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: '分流',
  splitTunnelSettingSubtitleOn: '已開啟 — 選定的流量不經過中繼。',
  splitTunnelSettingSubtitleOff: '已關閉 — 所有流量都經過中繼。',
  splitTunnelHeader: '分流',
  splitTunnelMasterTitle: '分流',
  splitTunnelMasterSubtitle: '讓選定的流量繞過中繼通道。',
  splitTunnelBypassHeader: '繞行',
  splitTunnelLanTitle: '區域網路',
  splitTunnelLanSubtitle: '直接連線印表機、電視等區域網路裝置。',
  splitTunnelIranTitle: '伊朗網站與應用程式',
  splitTunnelIranSubtitle: '將伊朗服務直連，享有全速體驗。',
  splitTunnelChinaTitle: '中國網站與應用程式',
  splitTunnelChinaSubtitle: '將中國服務直連，享有全速體驗。',
  splitTunnelAppsHeader: '應用程式',
  splitTunnelAppsTitle: '繞行的應用程式',
  splitTunnelAppsSubtitle: (count: number) => `${count} 個應用程式不走 VPN。`,
  splitTunnelAppPickerTitle: '繞行的應用程式',
  splitTunnelAppPickerLoading: '正在載入已安裝的應用程式…',
  splitTunnelAppPickerEmpty: '找不到可啟動的應用程式。',
  splitTunnelAppPickerClose: '關閉',
  splitTunnelApplyHint: '變更會立即生效；通道將重新連線幾秒鐘。',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: '需要更新',
  updateRequiredBody:
    '此版本的 OpenRung 已無法連線至中繼網路。請安裝最新版本以繼續使用。',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: '更新',
  updateActionLater: '稍後',
  updateContinueAnyway: '仍要繼續',
  updateBannerTitle: '有可用更新',
  updateBannerBody: (latest: string) =>
    `${latest} 版包含重要修正。方便時更新即可。`,
  updateSettingTitle: '有可用更新',
  updateSettingSubtitle: (current: string, latest: string) =>
    `你目前使用 v${current}；v${latest} 已推出。點選即可取得。`,
  noticeDismiss: '關閉',
  noticeLearnMore: '瞭解更多',
};
