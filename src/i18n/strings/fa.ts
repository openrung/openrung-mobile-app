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
  trafficRouteConnected: 'مسیر ترافیک: دستگاه -> OpenRung VPN -> رله',
  trafficRouteDisconnected: 'VPN در حالت fail-closed است: بدون رله، اتصال برقرار نمی‌شود.',
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
  licensesFullTextTitle: 'متن کامل مجوزها',
  licensesFullTextSubtitle: 'GNU GPL-3.0 و اعلان‌های اشخاص ثالث.',
  licensesComponentsHeader: 'مؤلفه‌ها',

  // Home tagline + about screen.
  homeTagline: 'شبکهٔ رله‌ها',
  aboutMissionBody:
    'OpenRung ترافیک شما را از طریق رله‌های سراسر جهان هدایت می‌کند و دسترسی به اینترنت آزاد را هنگام فیلتر شدن شبکه‌ها حفظ می‌کند. نیازی به حساب کاربری نیست و تبلیغی وجود ندارد. در دورهٔ آزمایش اولیه، OpenRung برای بهبود پایداری، فرادادهٔ تشخیصی اتصال را جمع‌آوری می‌کند.',
  aboutHowHeader: 'چگونه کار می‌کند',
  aboutProjectHeader: 'پروژه',
  aboutHow1Title: 'اپراتورهای رله ظرفیت فراهم می‌کنند',
  aboutHow1Body:
    'بنیاد OpenRung و داوطلبان جامعه رله‌ها را اجرا و در شبکه ثبت می‌کنند.',
  aboutHow2Title: 'کارگزار رلهٔ شما را پیدا می‌کند',
  aboutHow2Body:
    'هنگامی که متصل می‌شوید، کارگزار فهرست کوتاهی از رله‌های سالم را به دستگاه شما می‌دهد و برنامه اولین رله‌ای را که پاسخ دهد انتخاب می‌کند.',
  aboutHow3Title: 'ترافیک از یک تونل رمزنگاری‌شده عبور می‌کند',
  aboutHow3Body:
    'همه‌چیز از طریق یک تونل VLESS/REALITY جریان می‌یابد که شبیه TLS معمولی به نظر می‌رسد، و VPN در حالت fail-closed است: بدون رله، بدون ترافیک.',
  aboutFootnote:
    'OpenRung نرم‌افزار آزاد است (GPL-3.0-or-later). ساخته‌شده توسط داوطلبان، برای همه.',
};
