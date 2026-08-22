import type { Strings } from './en';

/** Ported from `res/values-vi/strings.xml`; missing keys fall back to English. */
export const vi: Partial<Strings> = {
  appName: 'OpenRung',
  actionConnect: 'KẾT NỐI',
  actionDisconnect: 'NGẮT KẾT NỐI',
  readyLog: 'sẵn sàng. nhấn kết nối để định tuyến qua relay.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  settingsTitle: 'Cài đặt',
  backContentDescription: 'Quay lại',
  languageSettingTitle: 'Ngôn ngữ',
  languageSettingSubtitle:
    'Dùng ngôn ngữ hệ thống hoặc chọn ngôn ngữ cho OpenRung.',
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
  relayClassOfficial: 'chính thức',
  relayClassVolunteer: 'tình nguyện',
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
  speedTestReady:
    'Tải xuống 10 MB qua relay đang hoạt động và báo cáo kết quả.',
  speedTestRequiresConnection:
    'Kết nối với relay trước khi chạy kiểm tra tốc độ.',
  speedTestRunning: 'Đang kiểm tra tốc độ tải xuống qua relay…',
  speedTestResult: (mbps: number) =>
    `Tốc độ tải xuống: ${mbps.toFixed(1)} Mbps`,
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
  viewToggleMap: 'Bản đồ',
  viewToggleList: 'Danh sách',
  listContentDescription: 'Danh sách các nút thoát khả dụng',
  listRelayCount: (count: number) =>
    count === 1 ? '1 relay' : `${count} relay`,

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
  shareTestFlightTitle: 'Chia sẻ OpenRung',
  shareTestFlightSubtitle:
    'Gửi liên kết TestFlight để người khác cài bản beta iOS.',
  shareTestFlightMessage: 'Tham gia bản beta OpenRung trên TestFlight:',
  shareTestFlightErrorTitle: 'Không thể chia sẻ OpenRung',
  shareTestFlightErrorBody:
    'Không thể chia sẻ liên kết TestFlight. Hãy thử lại.',

  // Home overlay and about screen.
  homeTagline: 'mạng lưới relay',
  aboutMissionLead:
    'Chúng tôi tin rằng truy cập internet là một quyền, không phải đặc ân',
  aboutMissionBody:
    'và không phải quân bài mặc cả để những người nắm quyền đem ra trao đổi. Quyền tiếp cận thông tin nằm trong chính bản chất con người, và không tường lửa nào được phép xóa bỏ quyền đó. Thế nhưng ngày nay, hàng tỷ người sống sau những bức tường được dựng lên để ngăn thông tin đi vào và giữ sự im lặng ở lại; nơi một tìm kiếm Google trả về lỗi 404, một câu hỏi có thể trở nên nguy hiểm và sự tò mò kết thúc tại một trang bị chặn.\n\nOpenRung tồn tại để thay đổi điều đó.\n\nChúng tôi đang dựng một chiếc thang vượt qua những bức tường ấy. Những người bình thường trên khắp thế giới chia sẻ kết nối của họ để ai đó ở phía bên kia tường lửa có thể tiếp cận internet mở.\n\nThông tin là sức mạnh, và sức mạnh đó thuộc về chúng ta, không thuộc về những kẻ muốn lấy nó khỏi tay chúng ta.',
  aboutSupportHeader: 'Ủng hộ chúng tôi',
  donateTitle: 'Quyên góp',
  donateSubtitle:
    'Giúp chiếc thang luôn đứng vững. Các khoản quyên góp được chuyển đến OpenRung Foundation.',
  aboutLegalHeader: 'Pháp lý',
  aboutFollowHeader: 'Theo dõi chúng tôi',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'Chia đường hầm',
  splitTunnelSettingSubtitleOn: 'Bật — lưu lượng được chọn đi vòng qua relay.',
  splitTunnelSettingSubtitleOff: 'Tắt — toàn bộ lưu lượng đi qua relay.',
  splitTunnelHeader: 'Chia đường hầm',
  splitTunnelMasterTitle: 'Chia đường hầm',
  splitTunnelMasterSubtitle:
    'Gửi lưu lượng được chọn ra ngoài đường hầm relay.',
  splitTunnelBypassHeader: 'Đi vòng',
  splitTunnelLanTitle: 'Mạng cục bộ',
  splitTunnelLanSubtitle:
    'Truy cập trực tiếp máy in, TV và các thiết bị mạng cục bộ khác.',
  splitTunnelIranTitle: 'Trang web & ứng dụng Iran',
  splitTunnelIranSubtitle:
    'Định tuyến trực tiếp các dịch vụ Iran với tốc độ tối đa.',
  splitTunnelChinaTitle: 'Trang web & ứng dụng Trung Quốc',
  splitTunnelChinaSubtitle:
    'Định tuyến trực tiếp các dịch vụ Trung Quốc với tốc độ tối đa.',
  splitTunnelAppsHeader: 'Ứng dụng',
  splitTunnelAppsTitle: 'Ứng dụng đi vòng',
  splitTunnelAppsSubtitle: (count: number) =>
    `${count} ứng dụng không đi qua VPN.`,
  splitTunnelAppPickerTitle: 'Ứng dụng đi vòng',
  splitTunnelAppPickerLoading: 'đang tải các ứng dụng đã cài…',
  splitTunnelAppPickerEmpty: 'không tìm thấy ứng dụng khởi chạy được.',
  splitTunnelAppPickerClose: 'ĐÓNG',
  splitTunnelApplyHint:
    'thay đổi áp dụng ngay; đường hầm sẽ kết nối lại trong vài giây.',
  splitTunnelResetHint:
    'các thiết lập sẵn cho Iran và Trung Quốc sẽ đặt lại khi bạn mở lại ứng dụng.',
  splitTunnelResetHintWithApps:
    'các thiết lập sẵn cho Iran và Trung Quốc sẽ đặt lại khi bạn mở lại ứng dụng; các ứng dụng được bỏ qua vẫn được giữ.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'Cần cập nhật',
  updateRequiredBody:
    'Phiên bản OpenRung này không còn kết nối được với mạng lưới relay. Hãy cài bản mới nhất để tiếp tục sử dụng.',
  updateVersionTransition: (current: string, latest: string) =>
    `v${current} -> v${latest}`,
  updateActionNow: 'CẬP NHẬT',
  updateActionLater: 'Để sau',
  updateContinueAnyway: 'Vẫn tiếp tục',
  updateBannerTitle: 'Có bản cập nhật',
  updateBannerBody: (latest: string) =>
    `Phiên bản ${latest} có các bản sửa lỗi quan trọng. Hãy cập nhật khi có thể.`,
  updateSettingTitle: 'Có bản cập nhật',
  updateSettingSubtitle: (current: string, latest: string) =>
    `Bạn đang dùng v${current}; v${latest} đã ra mắt. Nhấn để tải về.`,
  noticeDismiss: 'Bỏ qua',
  noticeLearnMore: 'Tìm hiểu thêm',
};
