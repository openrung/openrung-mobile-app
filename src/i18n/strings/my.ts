import type { Strings } from './en';

/** Ported from `res/values-my/strings.xml`; missing keys fall back to English. */
export const my: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `အခြေအနေ = ${status}`,
  relayFormat: (relay: string) => `relay = ${relay}`,
  relayLocationUnknown: 'မသိသော တည်နေရာ',
  actionConnect: 'ချိတ်ဆက်မည်',
  actionDisconnect: 'ချိတ်ဆက်မှု ဖြုတ်မည်',
  readyLog:
    'အသင့်ဖြစ်ပါပြီ။ ရီလေးမှတစ်ဆင့် ချိတ်ဆက်ရန် ချိတ်ဆက်မည် ကိုနှိပ်ပါ။',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'traffic route: device -> OpenRung VPN -> relay',
  trafficRouteDisconnected: 'vpn သည် fail-closed ဖြစ်သည်: relay မရှိလျှင် ချိတ်ဆက်မှု မရှိပါ။',
  settingsContentDescription: 'ဆက်တင်များ ဖွင့်ရန်',
  settingsTitle: 'ဆက်တင်များ',
  backContentDescription: 'နောက်သို့',
  languageSettingTitle: 'ဘာသာစကား',
  languageSettingSubtitle:
    'စနစ်ဘာသာစကားကို သုံးပါ၊ သို့မဟုတ် OpenRung အတွက် ဘာသာစကားရွေးပါ။',
  versionSettingTitle: 'ဗားရှင်း',
  languageSystem: 'စနစ် မူလတန်ဖိုး',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'ချိတ်ဆက်မှု ပြတ်နေသည်',
  statusPreparing: 'VPN ကို ပြင်ဆင်နေသည်',
  statusConnecting: 'ချိတ်ဆက်နေသည်',
  statusConnected: 'ချိတ်ဆက်ပြီး',
  statusDisconnecting: 'ချိတ်ဆက်မှု ဖြုတ်နေသည်',
  statusFailed: 'မအောင်မြင်ပါ',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'ပင်မ',
  tabSettings: 'ဆက်တင်များ',
  tabAbout: 'ကျွန်ုပ်တို့အကြောင်း',
  aboutTitle: 'ကျွန်ုပ်တို့အကြောင်း',
  relayAuto: 'အလိုအလျောက် relay',
  settingsGeneralHeader: 'အထွေထွေ',
  settingsDiagnosticsHeader: 'စစ်ဆေးခြင်း',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'ကွန်ရက်',
  telemetryLinkHeader: 'ချိတ်ဆက်မှု',
  telemetryRelaysLabel: 'relay',
  telemetryLocationsLabel: 'တည်နေရာ',
  telemetryCountriesLabel: 'နိုင်ငံ',
  telemetryUptimeLabel: 'ကြာချိန်',

  // Open action (accessibility).
  openContentDescription: 'ဖွင့်ရန်',

  // Relay speed test.
  speedTestSettingTitle: 'ရီလေး အမြန်နှုန်း စမ်းသပ်ခြင်း',
  speedTestReady:
    'လက်ရှိ ရီလေးမှတစ်ဆင့် 10 MB ကို ဒေါင်းလုဒ်လုပ်ပြီး ရလဒ်ကို ဖော်ပြပါ။',
  speedTestRequiresConnection:
    'အမြန်နှုန်း စမ်းသပ်မှု မလုပ်မီ ရီလေးတစ်ခုသို့ ချိတ်ဆက်ပါ။',
  speedTestRunning:
    'ရီလေးမှတစ်ဆင့် ဒေါင်းလုဒ် အမြန်နှုန်းကို စမ်းသပ်နေသည်…',
  speedTestResult: (mbps: number) => `ဒေါင်းလုဒ် အမြန်နှုန်း: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `အမြန်နှုန်း စမ်းသပ်မှု မအောင်မြင်ပါ: ${error}`,
  speedTestAction: 'စမ်းသပ်မည်',

  // Map view (exit nodes).
  mapContentDescription:
    'အာရှ-ပစိဖိတ် ဒေသတစ်ဝှမ်းရှိ ရနိုင်သော ထွက်ပေါက်ဆုံမှတ်များ၏ မြေပုံ',
  mapLoading: 'ရနိုင်သော ထွက်ပေါက်ဆုံမှတ်များကို ရှာဖွေနေသည်…',
  mapFailed: 'ထွက်ပေါက်ဆုံမှတ်များ ရယူ၍မရပါ — ပြန်စမ်းရန် တို့ပါ',
  mapNodesAvailable: (count: number) => `တည်နေရာ ${count} ခု ရနိုင်သည်`,
  mapNoNodes: 'ယခုအချိန်တွင် ထွက်ပေါက်ဆုံမှတ် မရနိုင်ပါ',

  // Recent locations.
  recentsLabel: 'မကြာသေးမီက',
  recentsEmpty: 'မကြာသေးမီက တည်နေရာများ မရှိသေးပါ။',

  // Map / list view toggle.
  viewToggleMap: 'မြေပုံ',
  viewToggleList: 'စာရင်း',

  // List view (exit nodes).
  listContentDescription:
    'ရနိုင်သော ထွက်ပေါက်ဆုံမှတ်များ၏ စာရင်း',
  listRelayCount: (count: number) => (count === 1 ? 'ရီလေး 1 ခု' : `ရီလေး ${count} ခု`),

  // Debug console.
  debugSettingTitle: 'အမှားရှာဖွေခြင်း',
  debugSettingSubtitle: 'ချိတ်ဆက်မှု ကွန်ဆိုးလ်နှင့် စစ်ဆေးမှုများ။',
  debugTitle: 'အမှားရှာဖွေရေး ကွန်ဆိုးလ်',

  // Open-source licenses.
  licensesSettingTitle: 'ပွင့်လင်းအရင်းအမြစ် လိုင်စင်များ',
  licensesSettingSubtitle:
    'ပါဝင်သော ဆော့ဖ်ဝဲအတွက် လိုင်စင်များနှင့် ကျေးဇူးတင်လွှာ။',
  licensesTitle: 'ပွင့်လင်းအရင်းအမြစ် လိုင်စင်များ',
  licensesIntro:
    'OpenRung သည် sing-box ကို ချိတ်ဆက်အသုံးပြုသောကြောင့် GPL-3.0-or-later အောက်တွင် လိုင်စင်ရရှိထားသော အခမဲ့ဆော့ဖ်ဝဲ ဖြစ်သည်။ ဤ build အတွက် ပြည့်စုံသော သက်ဆိုင်ရာ အရင်းအမြစ်ကုဒ်ကို အောက်ပါ လင့်ခ်တွင် ရယူနိုင်သည်။',
  licensesSourceTitle: 'အရင်းအမြစ်ကုဒ်',
  privacyPolicyTitle: 'ကိုယ်ရေးအချက်အလက် မူဝါဒ',
  privacyPolicySubtitle:
    'OpenRung သည် beta စမ်းသပ်မှုဆိုင်ရာ အမှားရှာဖွေဒေတာနှင့် ကိုယ်ရေးအချက်အလက်များကို ကိုင်တွယ်ပုံ။',
  licensesFullTextTitle: 'လိုင်စင် စာသားအပြည့်အစုံ',
  licensesFullTextSubtitle: 'GNU GPL-3.0 နှင့် ပြင်ပ အသိပေးချက်များ။',
  licensesComponentsHeader: 'အစိတ်အပိုင်းများ',
  shareApkTitle: 'OpenRung ကို အင်တာနက်မလိုဘဲ မျှဝေပါ',
  shareApkSubtitle:
    'ဤ APK ကို အင်တာနက်မလိုဘဲ အနီးရှိ Android ဖုန်းသို့ ပို့ပါ။',
  shareApkErrorTitle: 'OpenRung ကို မျှဝေ၍မရပါ',
  shareApkErrorBody:
    'APK ကို မျှဝေ၍မရပါ။ OpenRung ကို ဖွင့်ထားပြီး ထပ်မံကြိုးစားပါ။',
  shareApkSplitInstallError:
    'ဤမိတ္တူကို APK ဖိုင်များစွာဖြင့် ထည့်သွင်းထားသဖြင့် လုံခြုံစွာ မျှဝေ၍မရပါ။ အင်တာနက်မလိုဘဲ မျှဝေရန် OpenRung ၏ သီးခြား APK ကို ထည့်သွင်းပါ။',

  // Home overlay tagline.
  homeTagline: 'ရီလေး ကွန်ရက်',

  // About screen (mission / how it works / project).
  aboutMissionBody:
    'OpenRung သည် ကမ္ဘာတစ်ဝှမ်းရှိ ရီလေးများမှတစ်ဆင့် သင့်ဒေတာအသွားအလာကို လမ်းကြောင်းချပေးပြီး၊ ကွန်ရက်များ စစ်ထုတ်ပိတ်ဆို့ခံရသည့်အခါ ပွင့်လင်းသော အင်တာနက်ကို ဆက်လက်အသုံးပြုနိုင်စေသည်။ အကောင့်မလိုအပ်ဘဲ ကြော်ငြာများလည်း မရှိပါ။ အစောပိုင်း စမ်းသပ်ကာလတွင် ယုံကြည်စိတ်ချရမှု မြှင့်တင်ရန် OpenRung သည် ချိတ်ဆက်မှုဆိုင်ရာ ရောဂါရှာဖွေ မက်တာဒေတာကို စုဆောင်းပါသည်။',
  aboutHowHeader: 'အလုပ်လုပ်ပုံ',
  aboutProjectHeader: 'ပရောဂျက်',
  aboutHow1Title: 'ရီလေး အော်ပရေတာများက ကွန်ရက်စွမ်းရည် ပံ့ပိုးပေးသည်',
  aboutHow1Body:
    'OpenRung Foundation နှင့် လူထု စေတနာ့ဝန်ထမ်းများက ရီလေးများကို လည်ပတ်ပြီး ကွန်ရက်တွင် မှတ်ပုံတင်ကြသည်။',
  aboutHow2Title: 'ကြားခံသည် သင့်ရီလေးကို ရှာဖွေပေးသည်',
  aboutHow2Body:
    'သင် ချိတ်ဆက်သည့်အခါ ကြားခံသည် သင့်စက်ပစ္စည်းသို့ ကောင်းမွန်သန်စွမ်းသော ရီလေးများ၏ စာရင်းတိုတစ်ခုကို ပေးအပ်ပြီး အက်ပ်သည် ပထမဆုံး တုံ့ပြန်သည့် ရီလေးကို ရွေးချယ်သည်။',
  aboutHow3Title: 'ဒေတာအသွားအလာသည် ကုဒ်ဝှက်ထားသော ဥမင်မှတစ်ဆင့် ဖြတ်သန်းသည်',
  aboutHow3Body:
    'အရာအားလုံးသည် သာမန် TLS နှင့် တူသော VLESS/REALITY ဥမင်မှတစ်ဆင့် စီးဆင်းသွားပြီး VPN သည် fail-closed ဖြစ်သည်: ရီလေးမရှိလျှင် ဒေတာအသွားအလာ မရှိပါ။',
  aboutFootnote:
    'OpenRung သည် အခမဲ့ဆော့ဖ်ဝဲ (GPL-3.0-or-later) ဖြစ်သည်။ စေတနာ့ဝန်ထမ်းများက အားလုံးအတွက် တည်ဆောက်ထားသည်။',
};
