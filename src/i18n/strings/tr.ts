import type { Strings } from './en';

/** Ported from `res/values-tr/strings.xml`; missing keys fall back to English. */
export const tr: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `durum = ${status}`,
  relayFormat: (relay: string) => `röle = ${relay}`,
  relayLocationUnknown: 'Bilinmeyen konum',
  actionConnect: 'BAĞLAN',
  actionDisconnect: 'BAĞLANTIYI KES',
  readyLog: "hazır. röle üzerinden yönlendirmek için bağlan'a dokunun.",
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'trafik yolu: cihaz -> OpenRung VPN -> röle',
  trafficRouteDisconnected: 'vpn fail-closed çalışır: röle yoksa bağlantı yok.',
  settingsContentDescription: 'Ayarları aç',
  settingsTitle: 'Ayarlar',
  backContentDescription: 'Geri',
  languageSettingTitle: 'Dil',
  languageSettingSubtitle: 'Sistem dilini kullanın veya OpenRung için bir dil seçin.',
  versionSettingTitle: 'Sürüm',
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
  relayAuto: 'otomatik röle',
  settingsGeneralHeader: 'Genel',
  settingsDiagnosticsHeader: 'Tanılama',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'AĞ',
  telemetryLinkHeader: 'BAĞLANTI',
  telemetryRelaysLabel: 'röleler',
  telemetryLocationsLabel: 'konumlar',
  telemetryCountriesLabel: 'ülkeler',
  telemetryUptimeLabel: 'süre',

  // Content description for the open action.
  openContentDescription: 'Aç',

  // Relay speed test (diagnostics).
  speedTestSettingTitle: 'Röle hız testi',
  speedTestReady: 'Aktif röle üzerinden 10 MB indirin ve sonucu bildirin.',
  speedTestRequiresConnection: 'Hız testini çalıştırmadan önce bir röleye bağlanın.',
  speedTestRunning: 'Röle üzerinden indirme hızı test ediliyor…',
  speedTestResult: (mbps: number) => `İndirme hızı: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `Hız testi başarısız: ${error}`,
  speedTestAction: 'ÇALIŞTIR',

  // Exit node map view.
  mapContentDescription: 'Asya-Pasifik bölgesindeki mevcut çıkış düğümlerinin haritası',
  mapLoading: 'mevcut çıkış düğümleri bulunuyor…',
  mapFailed: 'çıkış düğümleri yüklenemedi — yeniden denemek için dokunun',
  mapNodesAvailable: (count: number) => `${count} konum mevcut`,
  mapNoNodes: 'şu anda mevcut çıkış düğümü yok',

  // Recent locations.
  recentsLabel: 'Son kullanılanlar',
  recentsEmpty: 'Henüz son kullanılan konum yok.',

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

  // Home overlay tagline.
  homeTagline: 'röle ağı',

  // About screen (mission, how it works, project).
  aboutMissionBody:
    'OpenRung, trafiğinizi dünyanın dört bir yanındaki röleler üzerinden yönlendirir; böylece ağlar filtrelendiğinde açık internet erişilebilir kalır. Hesap gerekmez ve reklam yoktur. Erken test sırasında OpenRung, güvenilirliği artırmak için tanısal bağlantı meta verileri toplar.',
  aboutHowHeader: 'Nasıl çalışır',
  aboutProjectHeader: 'Proje',
  aboutHow1Title: 'Röle operatörleri kapasite sağlar',
  aboutHow1Body:
    'OpenRung Foundation ve topluluk gönüllüleri röleleri çalıştırıp bunları ağa kaydeder.',
  aboutHow2Title: 'Aracı rölenizi bulur',
  aboutHow2Body:
    'Bağlandığınızda aracı, cihazınıza sağlıklı rölelerden oluşan kısa bir liste verir ve uygulama yanıt veren ilk röleyi seçer.',
  aboutHow3Title: 'Trafik şifreli bir tünelden geçer',
  aboutHow3Body:
    'Her şey, sıradan TLS gibi görünen bir VLESS/REALITY tüneli üzerinden akar ve VPN fail-closed çalışır: röle yoksa trafik yok.',
  aboutFootnote:
    'OpenRung özgür bir yazılımdır (GPL-3.0-or-later). Gönüllüler tarafından, herkes için geliştirildi.',
};
