import type { Strings } from './en';

/** Ported from `res/values-ar/strings.xml`; missing keys fall back to English. */
export const ar: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `الحالة = ${status}`,
  relayFormat: (relay: string) => `المرحل = ${relay}`,
  relayLocationUnknown: 'موقع غير معروف',
  actionConnect: 'اتصال',
  actionDisconnect: 'قطع الاتصال',
  readyLog: 'جاهز. اضغط على «اتصال» للتوجيه عبر مُرحّل.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'مسار المرور: الجهاز -> OpenRung VPN -> مرحل',
  trafficRouteDisconnected: 'يعمل VPN بوضع fail-closed: لا مرحل، لا اتصال.',
  settingsContentDescription: 'فتح الإعدادات',
  settingsTitle: 'الإعدادات',
  backContentDescription: 'رجوع',
  languageSettingTitle: 'اللغة',
  languageSettingSubtitle: 'استخدم لغة النظام أو اختر لغة لـ OpenRung.',
  versionSettingTitle: 'الإصدار',
  languageSystem: 'افتراضي النظام',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'غير متصل',
  statusPreparing: 'جار تجهيز VPN',
  statusConnecting: 'جار الاتصال',
  statusConnected: 'متصل',
  statusDisconnecting: 'جار قطع الاتصال',
  statusFailed: 'فشل',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'الرئيسية',
  tabSettings: 'الإعدادات',
  tabAbout: 'من نحن',
  aboutTitle: 'من نحن',
  relayAuto: 'مرحّل تلقائي',
  settingsGeneralHeader: 'عام',
  settingsDiagnosticsHeader: 'التشخيص',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'الشبكة',
  telemetryLinkHeader: 'الوصلة',
  telemetryRelaysLabel: 'مرحّلات',
  telemetryLocationsLabel: 'مواقع',
  telemetryCountriesLabel: 'دول',
  telemetryUptimeLabel: 'مدة الاتصال',

  // Content description (accessibility).
  openContentDescription: 'فتح',

  // Relay speed test (settings + diagnostics).
  speedTestSettingTitle: 'اختبار سرعة المُرحّل',
  speedTestReady:
    'تنزيل 10 MB عبر المُرحّل النشط والإبلاغ عن النتيجة.',
  speedTestRequiresConnection: 'اتصل بمُرحّل قبل إجراء اختبار السرعة.',
  speedTestRunning: 'جار اختبار سرعة التنزيل عبر المُرحّل…',
  speedTestResult: (mbps: number) => `سرعة التنزيل: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `فشل اختبار السرعة: ${error}`,
  speedTestAction: 'تشغيل',

  // Map view (relay exit nodes).
  mapContentDescription:
    'خريطة عقد الخروج المتاحة في منطقة آسيا والمحيط الهادئ',
  mapLoading: 'جار تحديد مواقع عقد الخروج المتاحة…',
  mapFailed: 'تعذّر تحميل عقد الخروج — اضغط لإعادة المحاولة',
  mapNodesAvailable: (count: number) => `${count} موقع متاح`,
  mapNoNodes: 'لا توجد عقد خروج متاحة الآن',

  // Recents, map/list toggle, and list view.
  recentsLabel: 'الأخيرة',
  recentsEmpty: 'لا توجد مواقع حديثة بعد.',
  viewToggleMap: 'خريطة',
  viewToggleList: 'قائمة',
  listContentDescription: 'قائمة عقد الخروج المتاحة',
  listRelayCount: (count: number) =>
    count === 1 ? 'مُرحّل واحد' : `${count} مُرحّلات`,

  // Debug console (diagnostics).
  debugSettingTitle: 'تصحيح الأخطاء',
  debugSettingSubtitle: 'وحدة تحكم الاتصال والتشخيص.',
  debugTitle: 'وحدة تحكم التصحيح',

  // Open-source licenses screen.
  licensesSettingTitle: 'تراخيص المصدر المفتوح',
  licensesSettingSubtitle: 'التراخيص والإسناد للبرامج المُضمّنة.',
  licensesTitle: 'تراخيص المصدر المفتوح',
  licensesIntro:
    'OpenRung برمجية حرة مُرخّصة بموجب GPL-3.0-or-later لأنها ترتبط بـ sing-box. الكود المصدري الكامل المقابل لهذا الإصدار متاح عبر الرابط أدناه.',
  licensesSourceTitle: 'الكود المصدري',
  privacyPolicyTitle: 'سياسة الخصوصية',
  privacyPolicySubtitle:
    'كيفية تعامل OpenRung مع بيانات تشخيص النسخة التجريبية والمعلومات الشخصية.',
  licensesFullTextTitle: 'نصوص التراخيص الكاملة',
  licensesFullTextSubtitle: 'GNU GPL-3.0 وإشعارات الجهات الخارجية.',
  licensesComponentsHeader: 'المكوّنات',
  shareApkTitle: 'مشاركة OpenRung دون اتصال',
  shareApkSubtitle: 'أرسل ملف APK هذا إلى هاتف Android قريب دون إنترنت.',
  shareApkErrorTitle: 'تعذّرت مشاركة OpenRung',
  shareApkErrorBody:
    'تعذّرت مشاركة ملف APK. أبقِ OpenRung مفتوحًا وحاول مرة أخرى.',
  shareApkSplitInstallError:
    'ثُبّتت هذه النسخة من عدة ملفات APK ولا يمكن مشاركتها بأمان. ثبّت ملف APK المستقل لـ OpenRung لاستخدام المشاركة دون اتصال.',
  shareTestFlightTitle: 'مشاركة OpenRung',
  shareTestFlightSubtitle:
    'أرسل رابط TestFlight ليتمكّن الآخرون من تثبيت نسخة iOS التجريبية.',
  shareTestFlightMessage: 'انضم إلى نسخة OpenRung التجريبية عبر TestFlight:',
  shareTestFlightErrorTitle: 'تعذّرت مشاركة OpenRung',
  shareTestFlightErrorBody:
    'تعذّرت مشاركة رابط TestFlight. حاول مرة أخرى.',

  // Home overlay and about screen.
  homeTagline: 'شبكة المُرحّلات',
  aboutMissionBody:
    'يوجّه OpenRung حركة مرورك عبر مُرحّلات حول العالم، مع إبقاء الإنترنت المفتوح في المتناول عند تصفية الشبكات. لا حاجة إلى حساب ولا توجد إعلانات. خلال مرحلة الاختبار المبكر، يجمع OpenRung بيانات وصفية تشخيصية عن الاتصال لتحسين الموثوقية.',
  aboutHowHeader: 'كيف يعمل',
  aboutProjectHeader: 'المشروع',
  aboutHow1Title: 'مشغّلو المُرحّلات يوفّرون السعة',
  aboutHow1Body:
    'تشغّل مؤسسة OpenRung ومتطوّعو المجتمع مُرحِّلات ويسجّلونها في الشبكة.',
  aboutHow2Title: 'الوسيط يعثر على مُرحّلك',
  aboutHow2Body:
    'عند الاتصال، يُسلّم الوسيط جهازك قائمة قصيرة بالمُرحّلات السليمة، ويختار التطبيق أوّل مُرحّل يستجيب.',
  aboutHow3Title: 'المرور يعبُر نفقًا مشفّرًا',
  aboutHow3Body:
    'يتدفّق كل شيء عبر نفق VLESS/REALITY يبدو كأنه TLS عادي، ويعمل VPN بوضع fail-closed: لا مرحل، لا مرور.',
  aboutFootnote:
    'OpenRung برمجية حرة (GPL-3.0-or-later). بناه متطوّعون، للجميع.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'التحديث مطلوب',
  updateRequiredBody:
    'لم يعد بإمكان هذا الإصدار من OpenRung الاتصال بشبكة المُرحّلات. ثبّت أحدث إصدار للمتابعة.',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: 'تحديث',
  updateActionLater: 'لاحقًا',
  updateContinueAnyway: 'المتابعة على أي حال',
  updateBannerTitle: 'يتوفر تحديث',
  updateBannerBody: (latest: string) =>
    `يتضمّن الإصدار ${latest} إصلاحات مهمة. حدّث عندما تستطيع.`,
  updateSettingTitle: 'يتوفر تحديث',
  updateSettingSubtitle: (current: string, latest: string) =>
    `لديك v${current}؛ وصدر v${latest}. اضغط للحصول عليه.`,
  noticeDismiss: 'تجاهل',
  noticeLearnMore: 'معرفة المزيد',
};
