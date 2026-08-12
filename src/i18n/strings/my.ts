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
  relayClassOfficial: 'တရားဝင်',
  relayClassVolunteer: 'စေတနာ့ဝန်ထမ်း',
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
  shareTestFlightTitle: 'OpenRung ကို မျှဝေပါ',
  shareTestFlightSubtitle:
    'iOS beta ကို ထည့်သွင်းနိုင်ရန် TestFlight လင့်ခ်ကို ပေးပို့ပါ။',
  shareTestFlightMessage: 'TestFlight တွင် OpenRung beta သို့ ပါဝင်ပါ –',
  shareTestFlightErrorTitle: 'OpenRung ကို မျှဝေ၍မရပါ',
  shareTestFlightErrorBody:
    'TestFlight လင့်ခ်ကို မျှဝေ၍မရပါ။ ထပ်မံကြိုးစားပါ။',

  // Home overlay and about screen.
  homeTagline: 'ရီလေး ကွန်ရက်',
  aboutMissionLead:
    'အင်တာနက် အသုံးပြုခွင့်သည် အခွင့်ထူးမဟုတ်ဘဲ အခွင့်အရေးဖြစ်သည်ဟု ကျွန်ုပ်တို့ ယုံကြည်သည်',
  aboutMissionBody:
    'အာဏာရှိသူများ အလဲအလှယ်လုပ်နိုင်သည့် အရာတစ်ခုလည်း မဟုတ်ပါ။ သတင်းအချက်အလက် သိရှိပိုင်ခွင့်သည် လူသားဖြစ်ခြင်း၏ အခြေခံအစိတ်အပိုင်းတစ်ခုဖြစ်ပြီး မည်သည့် firewall ကမျှ ထိုအခွင့်အရေးကို ဖျောက်ဖျက်ခွင့်မရှိပါ။ သို့သော် ယနေ့တွင် လူဘီလီယံပေါင်းများစွာသည် သတင်းအချက်အလက်ကို အပြင်တွင်ထားပြီး တိတ်ဆိတ်မှုကို အတွင်းတွင်ပိတ်ထားသော နံရံများနောက်၌ နေထိုင်နေကြရသည်။ ထိုနေရာများတွင် Google ရှာဖွေမှုက 404 ကိုသာ ပြသသည်၊ မေးခွန်းတစ်ခုမေးခြင်းသည် အန္တရာယ်ရှိနိုင်ပြီး စူးစမ်းလိုစိတ်သည် ပိတ်ဆို့ထားသော စာမျက်နှာတစ်ခုတွင် အဆုံးသတ်သွားသည်။\n\nOpenRung သည် ထိုအခြေအနေကို ပြောင်းလဲရန် တည်ရှိသည်။\n\nကျွန်ုပ်တို့သည် ထိုနံရံများကို ကျော်နိုင်မည့် လှေကားတစ်စင်း တည်ဆောက်နေသည်။ ကမ္ဘာတစ်ဝှမ်းရှိ သာမန်လူများက မိမိတို့၏ အင်တာနက်ချိတ်ဆက်မှုကို မျှဝေကြပြီး firewall ၏ အခြားတစ်ဖက်ရှိ တစ်စုံတစ်ယောက်ကို ပွင့်လင်းသော အင်တာနက်သို့ ရောက်ရှိနိုင်စေသည်။\n\nသတင်းအချက်အလက်သည် စွမ်းအားဖြစ်သည်။ ထိုစွမ်းအားသည် ကျွန်ုပ်တို့ပိုင်ဖြစ်ပြီး ကျွန်ုပ်တို့ထံမှ လုယူလိုသူများပိုင် မဟုတ်ပါ။',
  aboutLegalHeader: 'ဥပဒေဆိုင်ရာ',
  aboutFollowHeader: 'ကျွန်ုပ်တို့ကို လိုက်နာပါ',


  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'ဥမင် ခွဲထုတ်ခြင်း',
  splitTunnelSettingSubtitleOn:
    'ဖွင့်ထားသည် — ရွေးချယ်ထားသော ဒေတာအသွားအလာသည် ရီလေးကို ကျော်သွားသည်။',
  splitTunnelSettingSubtitleOff:
    'ပိတ်ထားသည် — ဒေတာအသွားအလာ အားလုံး ရီလေးမှတစ်ဆင့် သွားသည်။',
  splitTunnelHeader: 'ဥမင် ခွဲထုတ်ခြင်း',
  splitTunnelMasterTitle: 'ဥမင် ခွဲထုတ်ခြင်း',
  splitTunnelMasterSubtitle:
    'ရွေးချယ်ထားသော ဒေတာအသွားအလာကို ရီလေး ဥမင်အပြင်ဘက်မှ ပို့ပါ။',
  splitTunnelBypassHeader: 'ကျော်လွှားခြင်း',
  splitTunnelLanTitle: 'ဒေသတွင်း ကွန်ရက်',
  splitTunnelLanSubtitle:
    'ပရင်တာ၊ တီဗီနှင့် အခြား ဒေသတွင်းကွန်ရက် စက်များကို တိုက်ရိုက် ချိတ်ဆက်ပါ။',
  splitTunnelIranTitle: 'အီရန် ဝဘ်ဆိုက်နှင့် အက်ပ်များ',
  splitTunnelIranSubtitle:
    'အီရန် ဝန်ဆောင်မှုများကို အမြန်နှုန်းအပြည့်ဖြင့် တိုက်ရိုက် လမ်းကြောင်းချပါ။',
  splitTunnelChinaTitle: 'တရုတ် ဝဘ်ဆိုက်နှင့် အက်ပ်များ',
  splitTunnelChinaSubtitle:
    'တရုတ် ဝန်ဆောင်မှုများကို အမြန်နှုန်းအပြည့်ဖြင့် တိုက်ရိုက် လမ်းကြောင်းချပါ။',
  splitTunnelAppsHeader: 'အက်ပ်များ',
  splitTunnelAppsTitle: 'ကျော်လွှားသော အက်ပ်များ',
  splitTunnelAppsSubtitle: (count: number) =>
    `အက်ပ် ${count} ခုသည် VPN ကို ကျော်သွားသည်။`,
  splitTunnelAppPickerTitle: 'ကျော်လွှားသော အက်ပ်များ',
  splitTunnelAppPickerLoading: 'ထည့်သွင်းထားသော အက်ပ်များကို ရယူနေသည်…',
  splitTunnelAppPickerEmpty: 'ဖွင့်နိုင်သော အက်ပ် မတွေ့ပါ။',
  splitTunnelAppPickerClose: 'ပိတ်မည်',
  splitTunnelApplyHint:
    'ပြောင်းလဲမှုများ ချက်ချင်း သက်ရောက်သည်။ ဥမင်သည် စက္ကန့်အနည်းငယ် ပြန်လည်ချိတ်ဆက်မည်။',
  splitTunnelResetHint: 'အက်ပ်ကို ပြန်စတင်သည့်အခါ အီရန်နှင့် တရုတ် သတ်မှတ်ချက်များ ပြန်လည်သတ်မှတ်မည်။',
  splitTunnelResetHintWithApps:
    'အက်ပ်ကို ပြန်စတင်သည့်အခါ အီရန်နှင့် တရုတ် သတ်မှတ်ချက်များ ပြန်လည်သတ်မှတ်မည်။ ချွင်းချက်ပြုထားသော အက်ပ်များကို ထိန်းသိမ်းထားမည်။',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'အပ်ဒိတ် လုပ်ရန် လိုအပ်သည်',
  updateRequiredBody:
    'ဤ OpenRung ဗားရှင်းသည် ရီလေး ကွန်ရက်သို့ ချိတ်ဆက်၍ မရတော့ပါ။ ဆက်လက်အသုံးပြုနိုင်ရန် နောက်ဆုံးထွက် ဗားရှင်းကို ထည့်သွင်းပါ။',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: 'အပ်ဒိတ်လုပ်မည်',
  updateActionLater: 'နောက်မှ',
  updateContinueAnyway: 'မည်သို့ပင်ဖြစ်စေ ဆက်လုပ်မည်',
  updateBannerTitle: 'အပ်ဒိတ် ရနိုင်ပါပြီ',
  updateBannerBody: (latest: string) =>
    `ဗားရှင်း ${latest} တွင် အရေးကြီးသော ပြင်ဆင်ချက်များ ပါဝင်သည်။ အဆင်ပြေချိန်တွင် အပ်ဒိတ်လုပ်ပါ။`,
  updateSettingTitle: 'အပ်ဒိတ် ရနိုင်ပါပြီ',
  updateSettingSubtitle: (current: string, latest: string) =>
    `သင် v${current} ကို သုံးနေပြီး v${latest} ထွက်ရှိပြီးဖြစ်သည်။ ရယူရန် တို့ပါ။`,
  noticeDismiss: 'ပိတ်မည်',
  noticeLearnMore: 'ပိုမိုလေ့လာရန်',
};
