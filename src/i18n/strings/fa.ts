import type { Strings } from './en';

/** Ported from `res/values-fa/strings.xml`; missing keys fall back to English. */
export const fa: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `وضعیت = ${status}`,
  relayFormat: (relay: string) => `رله = ${relay}`,
  relayLocationUnknown: 'موقعیت نامشخص',
  actionConnect: 'اتصال',
  actionDisconnect: 'قطع اتصال',
  readyLog: 'آماده است. برای عبور از رله، روی اتصال ضربه بزنید.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  settingsContentDescription: 'باز کردن تنظیمات',
  settingsTitle: 'تنظیمات',
  backContentDescription: 'بازگشت',
  languageSettingTitle: 'زبان',
  languageSettingSubtitle: 'از زبان سیستم استفاده کنید یا زبانی برای OpenRung انتخاب کنید.',
  versionSettingTitle: 'نسخه',
  languageSystem: 'پیش‌فرض سیستم',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'قطع شده',
  statusPreparing: 'در حال آماده‌سازی VPN',
  statusConnecting: 'در حال اتصال',
  statusConnected: 'متصل',
  statusDisconnecting: 'در حال قطع اتصال',
  statusFailed: 'ناموفق',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'خانه',
  tabSettings: 'تنظیمات',
  tabAbout: 'درباره ما',
  aboutTitle: 'درباره ما',
  relayAuto: 'رله خودکار',
  relayClassOfficial: 'رسمی',
  relayClassVolunteer: 'داوطلب',
  settingsGeneralHeader: 'عمومی',
  settingsDiagnosticsHeader: 'عیب‌یابی',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'شبکه',
  telemetryLinkHeader: 'پیوند',
  telemetryRelaysLabel: 'رله‌ها',
  telemetryLocationsLabel: 'مکان‌ها',
  telemetryCountriesLabel: 'کشورها',
  telemetryUptimeLabel: 'مدت اتصال',

  // Content descriptions.
  openContentDescription: 'باز کردن',

  // Relay speed test.
  speedTestSettingTitle: 'تست سرعت رله',
  speedTestReady: 'از طریق رله فعال، 10 MB دانلود می‌کند و نتیجه را گزارش می‌دهد.',
  speedTestRequiresConnection: 'پیش از اجرای تست سرعت، به یک رله متصل شوید.',
  speedTestRunning: 'در حال تست سرعت دانلود از طریق رله…',
  speedTestResult: (mbps: number) => `سرعت دانلود: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `تست سرعت ناموفق بود: ${error}`,
  speedTestAction: 'اجرا',

  // Map view (exit nodes).
  mapContentDescription: 'نقشهٔ گره‌های خروجی موجود در سراسر منطقهٔ آسیا-اقیانوسیه',
  mapLoading: 'در حال یافتن گره‌های خروجی موجود…',
  mapFailed: 'بارگذاری گره‌های خروجی ناموفق بود — برای تلاش دوباره ضربه بزنید',
  mapNodesAvailable: (count: number) => `${count} مکان موجود`,
  mapNoNodes: 'در حال حاضر هیچ گره خروجی موجود نیست',

  // Recent locations.
  recentsLabel: 'اخیر',
  recentsEmpty: 'هنوز مکان اخیری وجود ندارد.',

  // Map / list toggle.
  viewToggleMap: 'نقشه',
  viewToggleList: 'فهرست',
  listContentDescription: 'فهرست گره‌های خروجی موجود',
  listRelayCount: (count: number) => (count === 1 ? '1 رله' : `${count} رله`),

  // Debug console.
  debugSettingTitle: 'اشکال‌زدایی',
  debugSettingSubtitle: 'کنسول اتصال و عیب‌یابی.',
  debugTitle: 'کنسول اشکال‌زدایی',

  // Open-source licenses.
  licensesSettingTitle: 'مجوزهای متن‌باز',
  licensesSettingSubtitle: 'مجوزها و ذکر منبع برای نرم‌افزارهای همراه.',
  licensesTitle: 'مجوزهای متن‌باز',
  licensesIntro:
    'OpenRung نرم‌افزار آزاد است و چون به sing-box پیوند می‌خورد، تحت مجوز GPL-3.0-or-later منتشر شده است. کد منبع کامل و متناظر این نسخه از طریق پیوند زیر در دسترس است.',
  licensesSourceTitle: 'کد منبع',
  privacyPolicyTitle: 'سیاست حفظ حریم خصوصی',
  privacyPolicySubtitle:
    'نحوهٔ مدیریت داده‌های تشخیصی نسخهٔ آزمایشی و اطلاعات شخصی توسط OpenRung.',
  licensesFullTextTitle: 'متن کامل مجوزها',
  licensesFullTextSubtitle: 'GNU GPL-3.0 و اعلان‌های اشخاص ثالث.',
  licensesComponentsHeader: 'مؤلفه‌ها',
  shareApkTitle: 'اشتراک‌گذاری آفلاین OpenRung',
  shareApkSubtitle:
    'این فایل APK را بدون اینترنت به یک گوشی Android نزدیک بفرستید.',
  shareApkErrorTitle: 'اشتراک‌گذاری OpenRung ممکن نیست',
  shareApkErrorBody:
    'فایل APK قابل اشتراک‌گذاری نبود. OpenRung را باز نگه دارید و دوباره تلاش کنید.',
  shareApkSplitInstallError:
    'این نسخه با چند فایل APK نصب شده است و نمی‌توان آن را به‌طور امن به اشتراک گذاشت. برای اشتراک‌گذاری آفلاین، فایل APK مستقل OpenRung را نصب کنید.',
  shareTestFlightTitle: 'اشتراک‌گذاری OpenRung',
  shareTestFlightSubtitle:
    'پیوند TestFlight را بفرستید تا دیگران بتای iOS را نصب کنند.',
  shareTestFlightMessage: 'در TestFlight به بتای OpenRung بپیوندید:',
  shareTestFlightErrorTitle: 'اشتراک‌گذاری OpenRung ممکن نیست',
  shareTestFlightErrorBody:
    'پیوند TestFlight به اشتراک گذاشته نشد. دوباره تلاش کنید.',

  // Home tagline + about screen.
  homeTagline: 'شبکهٔ رله‌ها',
  aboutMissionLead: 'ما باور داریم دسترسی به اینترنت یک حق است، نه یک امتیاز',
  aboutMissionBody:
    'و نه ابزار چانه‌زنی در دست صاحبان قدرت. حق دسترسی به اطلاعات در سرشت انسانی ما ریشه دارد و هیچ دیوار آتشی نباید اجازه داشته باشد آن را از بین ببرد. با این حال، امروز میلیاردها نفر پشت دیوارهایی زندگی می‌کنند که برای بیرون نگه داشتن اطلاعات و درون نگه داشتن سکوت ساخته شده‌اند؛ جایی که جست‌وجوی Google خطای 404 برمی‌گرداند، پرسیدن یک سؤال می‌تواند خطرناک باشد و کنجکاوی به یک صفحهٔ مسدودشده ختم می‌شود.\n\nOpenRung برای تغییر این وضعیت به وجود آمده است.\n\nما در حال ساختن نردبانی بر فراز این دیوارها هستیم. مردم عادی در سراسر جهان اتصال خود را به اشتراک می‌گذارند تا کسی در سوی دیگر یک دیوار آتش بتواند به اینترنت آزاد دسترسی پیدا کند.\n\nاطلاعات قدرت است و این قدرت به ما تعلق دارد، نه به کسانی که می‌خواهند آن را از ما بگیرند.',
  aboutLegalHeader: 'حقوقی',
  aboutFollowHeader: 'ما را دنبال کنید',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'تونل تفکیکی',
  splitTunnelSettingSubtitleOn: 'روشن — ترافیک انتخاب‌شده از رله عبور نمی‌کند.',
  splitTunnelSettingSubtitleOff: 'خاموش — همهٔ ترافیک از رله عبور می‌کند.',
  splitTunnelHeader: 'تونل تفکیکی',
  splitTunnelMasterTitle: 'تونل تفکیکی',
  splitTunnelMasterSubtitle: 'ترافیک انتخاب‌شده را بیرون از تونل رله بفرستید.',
  splitTunnelBypassHeader: 'عبور مستقیم',
  splitTunnelLanTitle: 'شبکهٔ محلی',
  splitTunnelLanSubtitle:
    'به چاپگرها، تلویزیون‌ها و دیگر دستگاه‌های شبکهٔ محلی مستقیم دسترسی داشته باشید.',
  splitTunnelIranTitle: 'سایت‌ها و برنامه‌های ایرانی',
  splitTunnelIranSubtitle: 'سرویس‌های ایرانی را مستقیم و با سرعت کامل هدایت کنید.',
  splitTunnelChinaTitle: 'سایت‌ها و برنامه‌های چینی',
  splitTunnelChinaSubtitle: 'سرویس‌های چینی را مستقیم و با سرعت کامل هدایت کنید.',
  splitTunnelAppsHeader: 'برنامه‌ها',
  splitTunnelAppsTitle: 'برنامه‌های خارج از VPN',
  splitTunnelAppsSubtitle: (count: number) =>
    count === 1 ? '1 برنامه VPN را دور می‌زند.' : `${count} برنامه VPN را دور می‌زنند.`,
  splitTunnelAppPickerTitle: 'برنامه‌های خارج از VPN',
  splitTunnelAppPickerLoading: 'در حال بارگذاری برنامه‌های نصب‌شده…',
  splitTunnelAppPickerEmpty: 'برنامهٔ قابل اجرا پیدا نشد.',
  splitTunnelAppPickerClose: 'بستن',
  splitTunnelApplyHint:
    'تغییرات بلافاصله اعمال می‌شوند؛ تونل برای چند ثانیه دوباره متصل می‌شود.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'به‌روزرسانی لازم است',
  updateRequiredBody:
    'این نسخه از OpenRung دیگر نمی‌تواند به شبکهٔ رله‌ها متصل شود. برای ادامه، آخرین نسخه را نصب کنید.',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: 'به‌روزرسانی',
  updateActionLater: 'بعداً',
  updateContinueAnyway: 'به هر حال ادامه دهید',
  updateBannerTitle: 'به‌روزرسانی موجود است',
  updateBannerBody: (latest: string) =>
    `نسخهٔ ${latest} شامل اصلاحات مهمی است. در اولین فرصت به‌روزرسانی کنید.`,
  updateSettingTitle: 'به‌روزرسانی موجود است',
  updateSettingSubtitle: (current: string, latest: string) =>
    `شما نسخهٔ v${current} را دارید؛ نسخهٔ v${latest} منتشر شده است. برای دریافت ضربه بزنید.`,
  noticeDismiss: 'بستن',
  noticeLearnMore: 'بیشتر بدانید',
};
