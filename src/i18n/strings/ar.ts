import type { Strings } from './en';

/** Ported from `res/values-ar/strings.xml`; missing keys fall back to English. */
export const ar: Partial<Strings> = {
  appName: 'OpenRung',
  actionConnect: 'اتصال',
  actionDisconnect: 'قطع الاتصال',
  readyLog: 'جاهز. اضغط على «اتصال» للتوجيه عبر مُرحّل.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  settingsTitle: 'الإعدادات',
  backContentDescription: 'رجوع',
  languageSettingTitle: 'اللغة',
  languageSettingSubtitle: 'استخدم لغة النظام أو اختر لغة لـ OpenRung.',
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
  relayClassOfficial: 'رسمي',
  relayClassVolunteer: 'متطوع',
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
  speedTestReady: 'تنزيل 10 MB عبر المُرحّل النشط والإبلاغ عن النتيجة.',
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
  shareTestFlightErrorBody: 'تعذّرت مشاركة رابط TestFlight. حاول مرة أخرى.',

  // Home overlay and about screen.
  homeTagline: 'شبكة المُرحّلات',
  aboutMissionLead: 'نؤمن بأن الوصول إلى الإنترنت حق، وليس امتيازًا',
  aboutMissionBody:
    'وليس ورقة مساومة يتداولها أصحاب السلطة. إن الحق في المعلومات متأصل في إنسانيتنا، ولا ينبغي السماح لأي جدار ناري بمَحوه. ومع ذلك، يعيش اليوم مليارات البشر خلف جدران بُنيت لإبقاء المعلومات خارجًا والصمت داخلًا؛ حيث يُرجع بحث Google خطأ 404، وقد يكون طرح سؤال أمرًا خطيرًا، وينتهي الفضول عند صفحة محجوبة.\n\nوُجد OpenRung ليغيّر ذلك.\n\nنحن نبني سُلّمًا يتجاوز تلك الجدران. يشارك أشخاص عاديون حول العالم اتصالاتهم كي يتمكن شخص على الجانب الآخر من جدار ناري من الوصول إلى الإنترنت المفتوح.\n\nالمعلومات قوة، وهذه القوة ملك لنا، لا لمن يريدون انتزاعها منا.',
  aboutSupportHeader: 'ادعمونا',
  donateTitle: 'تبرّع',
  donateSubtitle:
    'ساعدنا على إبقاء السلّم قائمًا. تذهب التبرعات إلى مؤسسة OpenRung.',
  aboutLegalHeader: 'الشؤون القانونية',
  aboutFollowHeader: 'تابعنا',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'تقسيم النفق',
  splitTunnelSettingSubtitleOn: 'مفعّل — المرور المحدد يتجاوز المُرحّل.',
  splitTunnelSettingSubtitleOff: 'متوقف — كل المرور يمر عبر المُرحّل.',
  splitTunnelHeader: 'تقسيم النفق',
  splitTunnelMasterTitle: 'تقسيم النفق',
  splitTunnelMasterSubtitle: 'أرسل المرور المحدد خارج نفق المُرحّل.',
  splitTunnelBypassHeader: 'تجاوز',
  splitTunnelLanTitle: 'الشبكة المحلية',
  splitTunnelLanSubtitle:
    'الوصول مباشرة إلى الطابعات وأجهزة التلفاز وسائر أجهزة الشبكة المحلية.',
  splitTunnelIranTitle: 'المواقع والتطبيقات الإيرانية',
  splitTunnelIranSubtitle: 'وجّه الخدمات الإيرانية مباشرة وبالسرعة الكاملة.',
  splitTunnelChinaTitle: 'المواقع والتطبيقات الصينية',
  splitTunnelChinaSubtitle: 'وجّه الخدمات الصينية مباشرة وبالسرعة الكاملة.',
  splitTunnelAppsHeader: 'التطبيقات',
  splitTunnelAppsTitle: 'التطبيقات المتجاوِزة',
  splitTunnelAppsSubtitle: (count: number) =>
    `التطبيقات التي تتجاوز VPN: ${count}.`,
  splitTunnelAppPickerTitle: 'التطبيقات المتجاوِزة',
  splitTunnelAppPickerLoading: 'جار تحميل التطبيقات المثبّتة…',
  splitTunnelAppPickerEmpty: 'لم يُعثر على تطبيقات قابلة للتشغيل.',
  splitTunnelAppPickerClose: 'إغلاق',
  splitTunnelApplyHint:
    'تُطبَّق التغييرات فورًا؛ يعيد النفق الاتصال لبضع ثوانٍ.',
  splitTunnelResetHint:
    'تُعاد إعدادات إيران والصين إلى الوضع الافتراضي عند إعادة تشغيل التطبيق.',
  splitTunnelResetHintWithApps:
    'تُعاد إعدادات إيران والصين إلى الوضع الافتراضي عند إعادة تشغيل التطبيق؛ أما التطبيقات المستثناة فتُحفظ.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'التحديث مطلوب',
  updateRequiredBody:
    'لم يعد بإمكان هذا الإصدار من OpenRung الاتصال بشبكة المُرحّلات. ثبّت أحدث إصدار للمتابعة.',
  updateVersionTransition: (current: string, latest: string) =>
    `v${current} -> v${latest}`,
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
