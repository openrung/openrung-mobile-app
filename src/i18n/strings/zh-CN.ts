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
  readyLog: '就绪。点按"连接"即可通过志愿者中继路由。',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: '流量路径：设备 -> OpenRung VPN -> 志愿者中继',
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

  // Volunteer speed test (settings screen).
  speedTestSettingTitle: '志愿者测速',
  speedTestReady: '通过当前活动的志愿者中继下载 10 MB 并报告结果。',
  speedTestRequiresConnection: '请先连接志愿者中继，再运行测速。',
  speedTestRunning: '正在通过志愿者中继测试下载速度…',
  speedTestResult: (mbps: number) => `下载速度：${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `测速失败：${error}`,
  speedTestAction: '运行',

  // Map view (volunteer exit nodes).
  mapContentDescription: '亚太地区可用志愿者出口节点的地图',
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

  // List view (volunteer exit nodes).
  listContentDescription: '可用志愿者出口节点列表',
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
  licensesFullTextTitle: '完整许可文本',
  licensesFullTextSubtitle: 'GNU GPL-3.0 及第三方声明。',
  licensesComponentsHeader: '组件',

  // Home tagline and about screen.
  homeTagline: '志愿者中继网络',
  aboutMissionBody:
    'OpenRung 通过世界各地志愿者运行的中继来路由你的流量，在网络被过滤时依然让开放互联网保持可达。没有账户、没有广告、没有追踪 — 只有人们共享带宽。',
  aboutHowHeader: '工作原理',
  aboutProjectHeader: '项目',
  aboutHow1Title: '志愿者共享带宽',
  aboutHow1Body:
    '世界各地的人们在自己的网络连接上运行小型中继节点，并将其注册到网络中。',
  aboutHow2Title: '中介为你找到中继',
  aboutHow2Body:
    '当你连接时，中介会向你的设备提供一份健康中继的简短列表，应用会选择第一个响应的中继。',
  aboutHow3Title: '流量通过加密隧道传输',
  aboutHow3Body:
    '所有流量都通过一条看起来像普通 TLS 的 VLESS/REALITY 隧道传输，并且 VPN 采用失败关闭：没有中继，就没有流量。',
  aboutFootnote:
    'OpenRung 是自由软件（GPL-3.0-or-later）。由志愿者打造，为所有人服务。',
};
