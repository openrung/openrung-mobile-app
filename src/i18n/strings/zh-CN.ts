import type { Strings } from './en';

/** Ported from `res/values-zh-rCN/strings.xml`; missing keys fall back to English. */
export const zhCN: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `状态 = ${status}`,
  relayFormat: (relay: string) => `中继 = ${relay}`,
  relayLocationUnknown: '未知位置',
  actionConnect: '连接',
  actionDisconnect: '断开连接',
  readyLog: '就绪。点按"连接"即可通过中继路由。',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  settingsContentDescription: '打开设置',
  settingsTitle: '设置',
  backContentDescription: '返回',
  languageSettingTitle: '语言',
  languageSettingSubtitle: '使用系统语言，或为 OpenRung 选择语言。',
  versionSettingTitle: '版本',
  languageSystem: '跟随系统',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: '已断开',
  statusPreparing: '正在准备 VPN',
  statusConnecting: '正在连接',
  statusConnected: '已连接',
  statusDisconnecting: '正在断开',
  statusFailed: '失败',

  // Redesigned shell (tabs / about / section headers).
  tabHome: '首页',
  tabSettings: '设置',
  tabAbout: '关于我们',
  aboutTitle: '关于我们',
  relayAuto: '自动中继',
  relayClassOfficial: '官方',
  relayClassVolunteer: '志愿',
  settingsGeneralHeader: '常规',
  settingsDiagnosticsHeader: '诊断',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: '网络',
  telemetryLinkHeader: '链路',
  telemetryRelaysLabel: '中继',
  telemetryLocationsLabel: '地点',
  telemetryCountriesLabel: '国家',
  telemetryUptimeLabel: '在线时长',

  // Generic open affordance (accessibility).
  openContentDescription: '打开',

  // Relay speed test (settings screen).
  speedTestSettingTitle: '中继测速',
  speedTestReady: '通过当前活动的中继下载 10 MB 并报告结果。',
  speedTestRequiresConnection: '请先连接中继，再运行测速。',
  speedTestRunning: '正在通过中继测试下载速度…',
  speedTestResult: (mbps: number) => `下载速度：${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `测速失败：${error}`,
  speedTestAction: '运行',

  // Map view (relay exit nodes).
  mapContentDescription: '亚太地区可用出口节点的地图',
  mapLoading: '正在定位可用的出口节点…',
  mapFailed: '无法加载出口节点 — 点按重试',
  mapNodesAvailable: (count: number) => `${count} 个地点可用`,
  mapNoNodes: '当前没有可用的出口节点',

  // Recent locations.
  recentsLabel: '最近使用',
  recentsEmpty: '暂无最近使用的地点。',

  // Map / list view toggle.
  viewToggleMap: '地图',
  viewToggleList: '列表',

  // List view (relay exit nodes).
  listContentDescription: '可用出口节点列表',
  listRelayCount: (count: number) => (count === 1 ? '1 个中继' : `${count} 个中继`),

  // Debug console (diagnostics).
  debugSettingTitle: '调试',
  debugSettingSubtitle: '连接控制台与诊断信息。',
  debugTitle: '调试控制台',

  // Open-source licenses.
  licensesSettingTitle: '开源许可',
  licensesSettingSubtitle: '捆绑软件的许可与署名。',
  licensesTitle: '开源许可',
  licensesIntro:
    'OpenRung 是自由软件，依据 GPL-3.0-or-later 授权，因为它链接了 sing-box。本次构建的完整对应源代码可通过下方链接获取。',
  licensesSourceTitle: '源代码',
  privacyPolicyTitle: '隐私政策',
  privacyPolicySubtitle: 'OpenRung 如何处理测试版诊断数据和个人信息。',
  licensesFullTextTitle: '完整许可文本',
  licensesFullTextSubtitle: 'GNU GPL-3.0 及第三方声明。',
  licensesComponentsHeader: '组件',
  shareApkTitle: '离线分享 OpenRung',
  shareApkSubtitle: '无需互联网，将此 APK 发送到附近的 Android 手机。',
  shareApkErrorTitle: '无法分享 OpenRung',
  shareApkErrorBody: '无法分享 APK。请保持 OpenRung 打开并重试。',
  shareApkSplitInstallError:
    '此版本由多个 APK 文件安装，无法安全分享。请安装 OpenRung 独立 APK 后使用离线分享。',
  shareTestFlightTitle: '分享 OpenRung',
  shareTestFlightSubtitle: '发送 TestFlight 链接，供他人安装 iOS 测试版。',
  shareTestFlightMessage: '通过 TestFlight 加入 OpenRung 测试版：',
  shareTestFlightErrorTitle: '无法分享 OpenRung',
  shareTestFlightErrorBody: '无法分享 TestFlight 链接。请重试。',

  // Home tagline and about screen.
  homeTagline: '中继网络',
  aboutMissionLead: '我们相信，互联网接入是一项权利，而不是特权',
  aboutMissionBody:
    '更不应成为掌权者用来交易的筹码。获取信息的权利根植于我们作为人的本质之中，任何防火墙都不应抹去它。然而今天，数十亿人生活在高墙之后；这些墙把信息挡在外面，把沉默困在里面。在那里，Google 搜索只返回 404，提出问题可能带来危险，好奇心止步于被屏蔽的页面。\n\nOpenRung 的存在就是为了改变这一切。\n\n我们正在搭建一架越过高墙的梯子。世界各地的普通人分享自己的网络连接，让防火墙另一边的人能够访问开放的互联网。\n\n信息就是力量，这份力量属于我们，而不属于那些企图从我们手中夺走它的人。',
  aboutLegalHeader: '法律信息',
  aboutFollowHeader: '关注我们',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: '分流',
  splitTunnelSettingSubtitleOn: '已开启 — 选定的流量不经过中继。',
  splitTunnelSettingSubtitleOff: '已关闭 — 所有流量都经过中继。',
  splitTunnelHeader: '分流',
  splitTunnelMasterTitle: '分流',
  splitTunnelMasterSubtitle: '让选定的流量绕过中继隧道。',
  splitTunnelBypassHeader: '绕行',
  splitTunnelLanTitle: '本地网络',
  splitTunnelLanSubtitle: '直接访问打印机、电视等局域网设备。',
  splitTunnelIranTitle: '伊朗网站与应用',
  splitTunnelIranSubtitle: '将伊朗服务直连，获得全速体验。',
  splitTunnelChinaTitle: '中国网站与应用',
  splitTunnelChinaSubtitle: '将中国服务直连，获得全速体验。',
  splitTunnelAppsHeader: '应用',
  splitTunnelAppsTitle: '绕行的应用',
  splitTunnelAppsSubtitle: (count: number) => `${count} 个应用不走 VPN。`,
  splitTunnelAppPickerTitle: '绕行的应用',
  splitTunnelAppPickerLoading: '正在加载已安装的应用…',
  splitTunnelAppPickerEmpty: '未找到可启动的应用。',
  splitTunnelAppPickerClose: '关闭',
  splitTunnelApplyHint: '更改会立即生效；隧道将重连几秒钟。',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: '需要更新',
  updateRequiredBody:
    '当前版本的 OpenRung 已无法连接中继网络。请安装最新版本以继续使用。',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: '立即更新',
  updateActionLater: '稍后',
  updateContinueAnyway: '仍然继续',
  updateBannerTitle: '有可用更新',
  updateBannerBody: (latest: string) =>
    `版本 ${latest} 包含重要修复。方便时更新即可。`,
  updateSettingTitle: '有可用更新',
  updateSettingSubtitle: (current: string, latest: string) =>
    `当前为 v${current}，最新版 v${latest} 已发布。点按获取。`,
  noticeDismiss: '关闭',
  noticeLearnMore: '了解更多',
};
