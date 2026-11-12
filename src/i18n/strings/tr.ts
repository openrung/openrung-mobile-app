import type { Strings } from './en';

/** Ported from `res/values-tr/strings.xml`; missing keys fall back to English. */
export const tr: Partial<Strings> = {
  appName: 'OpenRung',
  actionConnect: 'BAĞLAN',
  actionDisconnect: 'BAĞLANTIYI KES',
  readyLog: "hazır. röle üzerinden yönlendirmek için bağlan'a dokunun.",
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  settingsTitle: 'Ayarlar',
  backContentDescription: 'Geri',
  languageSettingTitle: 'Dil',
  languageSettingSubtitle:
    'Sistem dilini kullanın veya OpenRung için bir dil seçin.',
  languageSystem: 'Sistem varsayılanı',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'Bağlı değil',
  statusPreparing: 'VPN hazırlanıyor',
  statusConnecting: 'Bağlanıyor',
  statusConnected: 'Bağlandı',
  statusDisconnecting: 'Bağlantı kesiliyor',
  statusFailed: 'Başarısız',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'Ana sayfa',
  tabSettings: 'Ayarlar',
  tabAbout: 'Hakkımızda',
  aboutTitle: 'Hakkımızda',
  relayAuto: 'otomatik röle seçimi',
  widgetStatusDisconnected: 'Bağlı\ndeğil',
  widgetName: 'Hızlı bağlantı',
  widgetDescription:
    'Ana ekrandan otomatik seçilen bir röleye bağlanın.',
  relayClassOfficial: 'resmi',
  relayClassVolunteer: 'gönüllü',
  settingsGeneralHeader: 'Genel',
  settingsDiagnosticsHeader: 'Tanılama',

  // Content description for the open action.
  openContentDescription: 'Aç',

  // Speed test link (settings).
  speedTestSettingTitle: 'Hız testi',
  speedTestSettingSubtitle: 'fast.com adresini tarayıcınızda açar',
  speedTestRequiresConnection: 'Tüneli ölçmek için önce bağlanın',

  // Exit node map view.
  mapContentDescription:
    'Asya-Pasifik bölgesindeki mevcut çıkış düğümlerinin haritası',
  mapLoading: 'mevcut çıkış düğümleri bulunuyor…',
  mapFailed: 'çıkış düğümleri yüklenemedi — yeniden denemek için dokunun',
  mapRelaysOnline: (count: number) => `${count} röle çevrimiçi`,
  mapNoNodes: 'şu anda mevcut çıkış düğümü yok',

  // Recent locations.
  recentsLabel: 'Son kullanılanlar',

  // Map / list view toggle.
  viewToggleMap: 'Harita',
  viewToggleList: 'Liste',

  // Exit node list view.
  listContentDescription: 'Mevcut çıkış düğümlerinin listesi',
  listRelayCount: (count: number) => (count === 1 ? '1 röle' : `${count} röle`),

  // Debug console (diagnostics).
  debugSettingTitle: 'Hata ayıklama',
  debugSettingSubtitle: 'Bağlantı konsolu ve tanılama.',
  debugTitle: 'Hata ayıklama konsolu',

  // Open-source licenses screen.
  licensesSettingTitle: 'Açık kaynak lisansları',
  licensesSettingSubtitle: 'Paketlenmiş yazılımlar için lisanslar ve atıflar.',
  licensesTitle: 'Açık kaynak lisansları',
  licensesIntro:
    "OpenRung, sing-box'a bağlandığı için GPL-3.0-or-later ile lisanslanan özgür bir yazılımdır. Bu derlemeye karşılık gelen eksiksiz kaynak kodu aşağıdaki bağlantıda mevcuttur.",
  licensesSourceTitle: 'Kaynak kodu',
  privacyPolicyTitle: 'Gizlilik politikası',
  privacyPolicySubtitle:
    "OpenRung'un beta tanılama verilerini ve kişisel bilgileri nasıl işlediği.",
  licensesFullTextTitle: 'Tam lisans metinleri',
  licensesFullTextSubtitle: 'GNU GPL-3.0 ve üçüncü taraf bildirimleri.',
  licensesComponentsHeader: 'Bileşenler',
  shareApkTitle: "OpenRung'u çevrimdışı paylaş",
  shareApkSubtitle:
    "Bu APK'yı internet olmadan yakındaki bir Android telefona gönderin.",
  shareApkErrorTitle: 'OpenRung paylaşılamıyor',
  shareApkErrorBody: "APK paylaşılamadı. OpenRung'u açık tutup tekrar deneyin.",
  shareApkSplitInstallError:
    "Bu kopya birden fazla APK dosyasıyla yüklendiği için güvenle paylaşılamaz. Çevrimdışı paylaşım için bağımsız OpenRung APK'sını yükleyin.",
  shareTestFlightTitle: "OpenRung'u paylaş",
  shareTestFlightSubtitle:
    'Başkalarının iOS betasını kurabilmesi için TestFlight bağlantısı gönderin.',
  shareTestFlightMessage: "TestFlight'ta OpenRung betasına katılın:",
  shareTestFlightErrorTitle: 'OpenRung paylaşılamıyor',
  shareTestFlightErrorBody:
    'TestFlight bağlantısı paylaşılamadı. Tekrar deneyin.',

  // Home overlay and about screen.
  homeTagline: 'röle ağı',
  homeSlogan: 'İnternete erişim bir ayrıcalık değil, haktır',
  aboutMissionLead:
    'İnternete erişimin bir ayrıcalık değil, hak olduğuna inanıyoruz',
  aboutMissionBody:
    'Bu hak, iktidardakilerin pazarlık konusu yapabileceği bir koz değildir. Bilgi edinme hakkı insan oluşumuzun özünde vardır ve hiçbir güvenlik duvarının bunu silmesine izin verilmemelidir. Yine de bugün milyarlarca insan, bilgiyi dışarıda ve sessizliği içeride tutmak için örülmüş duvarların arkasında yaşıyor; Google aramasının 404 döndürdüğü, soru sormanın tehlikeli olabildiği ve merakın engellenmiş bir sayfada sona erdiği yerlerde.\n\nOpenRung bunu değiştirmek için var.\n\nBu duvarların üzerinden bir merdiven inşa ediyoruz. Dünyanın dört bir yanındaki sıradan insanlar bağlantılarını paylaşıyor; böylece bir güvenlik duvarının diğer tarafındaki biri açık internete ulaşabiliyor.\n\nBilgi güçtür ve bu güç, onu bizden almak isteyenlere değil, bize aittir.',
  aboutSupportHeader: 'Bize destek olun',
  donateTitle: 'Bağış yap',
  donateSubtitle:
    'Merdivenin ayakta kalmasına yardım edin. Bağışlar OpenRung Vakfı’na gider.',
  aboutLegalHeader: 'Yasal',
  aboutFollowHeader: 'Bizi takip edin',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'Bölünmüş tünel',
  splitTunnelSettingSubtitleOn: 'Açık — seçilen trafik röleyi atlar.',
  splitTunnelSettingSubtitleOff: 'Kapalı — tüm trafik röle üzerinden geçer.',
  splitTunnelHeader: 'Bölünmüş tünel',
  splitTunnelMasterTitle: 'Bölünmüş tünel',
  splitTunnelMasterSubtitle: 'Seçilen trafiği röle tünelinin dışına gönderin.',
  splitTunnelBypassHeader: 'Baypas',
  splitTunnelLanTitle: 'Yerel ağ',
  splitTunnelLanSubtitle:
    "Yazıcılara, TV'lere ve diğer yerel ağ cihazlarına doğrudan erişin.",
  splitTunnelIranTitle: 'İran siteleri ve uygulamaları',
  splitTunnelIranSubtitle: 'İran servislerini doğrudan, tam hızda yönlendirin.',
  splitTunnelChinaTitle: 'Çin siteleri ve uygulamaları',
  splitTunnelChinaSubtitle: 'Çin servislerini doğrudan, tam hızda yönlendirin.',
  splitTunnelAppsHeader: 'Uygulamalar',
  splitTunnelAppsTitle: 'Baypas edilen uygulamalar',
  splitTunnelAppsSubtitle: (count: number) =>
    `${count} uygulama VPN'i atlıyor.`,
  splitTunnelAppPickerTitle: 'Baypas edilen uygulamalar',
  splitTunnelAppPickerLoading: 'yüklü uygulamalar getiriliyor…',
  splitTunnelAppPickerEmpty: 'başlatılabilir uygulama bulunamadı.',
  splitTunnelAppPickerClose: 'KAPAT',
  splitTunnelApplyHint:
    'değişiklikler hemen uygulanır; tünel birkaç saniyeliğine yeniden bağlanır.',
  splitTunnelResetHint:
    'uygulamayı yeniden başlattığınızda İran ve Çin ön ayarları sıfırlanır.',
  splitTunnelResetHintWithApps:
    'uygulamayı yeniden başlattığınızda İran ve Çin ön ayarları sıfırlanır; hariç tutulan uygulamalar korunur.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'Güncelleme gerekli',
  updateRequiredBody:
    "OpenRung'un bu sürümü artık röle ağına bağlanamıyor. Devam edebilmek için en son sürümü yükleyin.",
  updateVersionTransition: (current: string, latest: string) =>
    `v${current} -> v${latest}`,
  updateActionNow: 'GÜNCELLE',
  updateActionLater: 'Daha sonra',
  updateContinueAnyway: 'Yine de devam et',
  updateBannerTitle: 'Güncelleme mevcut',
  updateBannerBody: (latest: string) =>
    `${latest} sürümü önemli düzeltmeler içeriyor. Fırsat bulduğunuzda güncelleyin.`,
  updateSettingTitle: 'Güncelleme mevcut',
  updateSettingSubtitle: (current: string, latest: string) =>
    `v${current} kullanıyorsunuz; v${latest} yayında. İndirmek için dokunun.`,
  noticeDismiss: 'Kapat',
  noticeLearnMore: 'Daha fazla bilgi',
  errorAccessDenied:
    'Bu cihazın erişimi devre dışı bırakıldı, bu yüzden bağlanamıyor. OpenRung destek ekibiyle iletişime geçin.',
  errorEnrollmentRefused:
    "Kayıt başarısız. Diğer VPN'leri kapatıp tekrar deneyin.",
  // Desktop client only: the local proxy rows in Settings (DesktopProxySection).
  desktopProxyHeader: 'Yerel proxy',
  desktopProxyEndpointTitle: 'Uç nokta',
  desktopProxyEndpointConnected: (endpoint: string) => `${endpoint} · şu anda kullanılabilir`,
  desktopProxyEndpointIdle: (endpoint: string) => `${endpoint} · bağlıyken kullanılabilir`,
  desktopProxyPreparing: 'Yerel proxy uç noktası hazırlanıyor…',
  desktopProxyPersistenceTitle: 'Uç nokta kalıcılığı',
  desktopShellIntegrationTitle: 'Kabuk entegrasyonu',
  desktopShellEnableTitle: 'Bu kabukta etkinleştir',
  desktopShellEnableSubtitle: 'Mevcut proxy değerlerini ve ayarlanmamış durumu korur.',
  desktopShellEnableRequiresConnection: "Bu kabukta etkinleştirmeden önce OpenRung'a bağlanın.",
  desktopShellRestoreTitle: 'Bu kabuğu geri yükle',
  desktopShellRestoreSubtitle: 'Bağlantı kesildikten, hata, çıkış veya çökmeden sonra çalıştırın.',
  desktopTunModeTitle: 'TUN modu',
  desktopTunModeSubtitleOff:
    'Kapalı. Yalnızca sistem proxy’sini kullanan uygulamalar OpenRung üzerinden geçer.',
  desktopTunModeSubtitleOn: 'Açık. Bu cihazın tüm trafiği OpenRung üzerinden geçer.',
  desktopTunModeRestartNote: 'Açmak, OpenRung’u yönetici haklarıyla yeniden başlatır.',
  desktopTunModeRequiresDisconnect: 'Modu değiştirmek için bağlantıyı kesin.',
  actionCopy: 'Kopyala',
  actionCopied: 'Kopyalandı',
};
