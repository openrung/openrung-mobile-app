import type { Strings } from './en';

/** Ported from `res/values-vi/strings.xml`; missing keys fall back to English. */
export const vi: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `trạng thái = ${status}`,
  relayFormat: (relay: string) => `relay = ${relay}`,
  relayLocationUnknown: 'Vị trí không xác định',
  actionConnect: 'KẾT NỐI',
  actionDisconnect: 'NGẮT KẾT NỐI',
  readyLog: 'sẵn sàng. nhấn kết nối để định tuyến qua relay.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected: 'đường đi lưu lượng: thiết bị -> OpenRung VPN -> relay',
  trafficRouteDisconnected: 'vpn ở chế độ fail-closed: không có relay, không kết nối.',
  settingsContentDescription: 'Mở cài đặt',
  settingsTitle: 'Cài đặt',
  backContentDescription: 'Quay lại',
  languageSettingTitle: 'Ngôn ngữ',
  languageSettingSubtitle: 'Dùng ngôn ngữ hệ thống hoặc chọn ngôn ngữ cho OpenRung.',
  versionSettingTitle: 'Phiên bản',
  languageSystem: 'Mặc định hệ thống',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'Đã ngắt kết nối',
  statusPreparing: 'Đang chuẩn bị VPN',
  statusConnecting: 'Đang kết nối',
  statusConnected: 'Đã kết nối',
  statusDisconnecting: 'Đang ngắt kết nối',
  statusFailed: 'Thất bại',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'Trang chủ',
  tabSettings: 'Cài đặt',
  tabAbout: 'Về chúng tôi',
  aboutTitle: 'Về chúng tôi',
  relayAuto: 'relay tự động',
  settingsGeneralHeader: 'Chung',
  settingsDiagnosticsHeader: 'Chẩn đoán',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'MẠNG',
  telemetryLinkHeader: 'KẾT NỐI',
  telemetryRelaysLabel: 'relay',
  telemetryLocationsLabel: 'địa điểm',
  telemetryCountriesLabel: 'quốc gia',
  telemetryUptimeLabel: 'thời lượng',

  // Content description (open action).
  openContentDescription: 'Mở',

  // Relay speed test (diagnostics).
  speedTestSettingTitle: 'Kiểm tra tốc độ relay',
  speedTestReady: 'Tải xuống 10 MB qua relay đang hoạt động và báo cáo kết quả.',
  speedTestRequiresConnection: 'Kết nối với relay trước khi chạy kiểm tra tốc độ.',
  speedTestRunning: 'Đang kiểm tra tốc độ tải xuống qua relay…',
  speedTestResult: (mbps: number) => `Tốc độ tải xuống: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `Kiểm tra tốc độ thất bại: ${error}`,
  speedTestAction: 'CHẠY',

  // Map and list views (exit nodes).
  mapContentDescription:
    'Bản đồ các nút thoát khả dụng khắp khu vực Châu Á - Thái Bình Dương',
  mapLoading: 'đang định vị các nút thoát khả dụng…',
  mapFailed: 'không tải được các nút thoát — nhấn để thử lại',
  mapNodesAvailable: (count: number) => `${count} địa điểm khả dụng`,
  mapNoNodes: 'hiện không có nút thoát nào khả dụng',
  recentsLabel: 'Gần đây',
  recentsEmpty: 'Chưa có địa điểm gần đây.',
  viewToggleMap: 'Bản đồ',
  viewToggleList: 'Danh sách',
  listContentDescription: 'Danh sách các nút thoát khả dụng',
  listRelayCount: (count: number) => (count === 1 ? '1 relay' : `${count} relay`),

  // Debug console (diagnostics).
  debugSettingTitle: 'Gỡ lỗi',
  debugSettingSubtitle: 'Bảng điều khiển kết nối và chẩn đoán.',
  debugTitle: 'Bảng điều khiển gỡ lỗi',

  // Open-source licenses.
  licensesSettingTitle: 'Giấy phép nguồn mở',
  licensesSettingSubtitle: 'Giấy phép và ghi công cho phần mềm đi kèm.',
  licensesTitle: 'Giấy phép nguồn mở',
  licensesIntro:
    'OpenRung là phần mềm tự do được cấp phép theo GPL-3.0-or-later vì nó liên kết sing-box. Toàn bộ mã nguồn tương ứng của bản dựng này có sẵn tại liên kết bên dưới.',
  licensesSourceTitle: 'Mã nguồn',
  privacyPolicyTitle: 'Chính sách quyền riêng tư',
  privacyPolicySubtitle:
    'Cách OpenRung xử lý dữ liệu chẩn đoán bản beta và thông tin cá nhân.',
  licensesFullTextTitle: 'Toàn văn giấy phép',
  licensesFullTextSubtitle: 'GNU GPL-3.0 và thông báo của bên thứ ba.',
  licensesComponentsHeader: 'Thành phần',
  shareApkTitle: 'Chia sẻ OpenRung ngoại tuyến',
  shareApkSubtitle:
    'Gửi APK này đến một điện thoại Android ở gần mà không cần Internet.',
  shareApkErrorTitle: 'Không thể chia sẻ OpenRung',
  shareApkErrorBody:
    'Không thể chia sẻ APK. Hãy giữ OpenRung đang mở và thử lại.',
  shareApkSplitInstallError:
    'Bản này được cài bằng nhiều tệp APK nên không thể chia sẻ an toàn. Hãy cài APK OpenRung độc lập để dùng tính năng chia sẻ ngoại tuyến.',

  // Home overlay and about screen.
  homeTagline: 'mạng lưới relay',
  aboutMissionBody:
    'OpenRung định tuyến lưu lượng của bạn qua các relay trên khắp thế giới, giữ cho internet mở luôn truy cập được khi mạng bị lọc chặn. Không cần tài khoản và không có quảng cáo. Trong giai đoạn thử nghiệm sớm, OpenRung thu thập siêu dữ liệu chẩn đoán kết nối để cải thiện độ tin cậy.',
  aboutHowHeader: 'Cách hoạt động',
  aboutProjectHeader: 'Dự án',
  aboutHow1Title: 'Nhà vận hành relay cung cấp năng lực',
  aboutHow1Body:
    'OpenRung Foundation và các tình nguyện viên cộng đồng vận hành các relay và đăng ký chúng với mạng lưới.',
  aboutHow2Title: 'Bộ điều phối tìm relay cho bạn',
  aboutHow2Body:
    'Khi bạn kết nối, bộ điều phối trao cho thiết bị của bạn một danh sách ngắn các relay khỏe mạnh và ứng dụng chọn relay đầu tiên phản hồi.',
  aboutHow3Title: 'Lưu lượng đi qua đường hầm mã hóa',
  aboutHow3Body:
    'Mọi thứ đều đi qua một đường hầm VLESS/REALITY trông như TLS thông thường, và VPN ở chế độ fail-closed: không có relay, không có lưu lượng.',
  aboutFootnote:
    'OpenRung là phần mềm tự do (GPL-3.0-or-later). Được xây dựng bởi tình nguyện viên, cho mọi người.',
};
