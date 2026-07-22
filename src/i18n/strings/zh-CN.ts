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
  trafficRouteConnected: '流量路径：设备 -> OpenRung VPN -> 中继',
  trafficRouteDisconnected: 'VPN 采用失败关闭：没有中继，就不连接。',
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
  aboutMissionBody:
    'OpenRung 通过世界各地的中继来路由你的流量，在网络被过滤时依然让开放互联网保持可达。无需账户，也没有广告。在早期测试期间，OpenRung 会收集诊断性连接元数据，以提升可靠性。',
  aboutHowHeader: '工作原理',
  aboutProjectHeader: '项目',
  aboutHow1Title: '中继运营者提供网络容量',
  aboutHow1Body:
    'OpenRung 基金会和社区志愿者运行中继，并将其注册到网络中。',
  aboutHow2Title: '中介为你找到中继',
  aboutHow2Body:
    '当你连接时，中介会向你的设备提供一份健康中继的简短列表，应用会选择第一个响应的中继。',
  aboutHow3Title: '流量通过加密隧道传输',
  aboutHow3Body:
    '所有流量都通过一条看起来像普通 TLS 的 VLESS/REALITY 隧道传输，并且 VPN 采用失败关闭：没有中继，就没有流量。',
  aboutFootnote:
    'OpenRung 是自由软件（GPL-3.0-or-later）。由志愿者打造，为所有人服务。',
};
