import Foundation

/// Widget copy for the languages the React Native shell already ships. Shared status strings
/// match `src/i18n`; widget-only lines live here because the extension cannot run JavaScript.
/// An empty stored tag follows the system locale with the same resolution rules as
/// `resolveLanguage` in `src/i18n/index.tsx`.
enum WidgetStrings {
    static let supported = ["en", "zh-CN", "zh-TW", "fa", "ru", "ar", "tr", "vi", "my"]
    static let rightToLeft: Set<String> = ["fa", "ar"]

    // widget-strings:en
    static let enTable: [String: String] = [
        "actionConnect": "CONNECT",
        "openContentDescription": "Open",
        "statusDisconnected": "Disconnected",
        "statusPreparing": "Preparing VPN",
        "statusConnecting": "Connecting",
        "statusConnected": "Connected",
        "statusDisconnecting": "Disconnecting",
        "statusFailed": "Failed",
        "relayAuto": "auto relay",
        "errorAccessDenied": "Access for this device has been disabled, so it cannot connect. Contact OpenRung support.",
        "errorEnrollmentRefused": "Registration failed. Disconnect other VPNs and retry.",
        "widgetSetupTitle": "Setup required",
        "widgetSetupDetail": "Open the app to allow the VPN",
        "widgetAccessibilityConnect": "Connect OpenRung to the automatic relay",
        "widgetAccessibilityOpen": "Open OpenRung",
    ]
    // widget-strings:end

    // widget-strings:zh-CN
    static let zhCNTable: [String: String] = [
        "actionConnect": "连接",
        "openContentDescription": "打开",
        "statusDisconnected": "已断开",
        "statusPreparing": "正在准备 VPN",
        "statusConnecting": "正在连接",
        "statusConnected": "已连接",
        "statusDisconnecting": "正在断开",
        "statusFailed": "失败",
        "relayAuto": "自动中继",
        "errorAccessDenied": "此设备的访问权限已被停用，无法连接。请联系 OpenRung 支持。",
        "errorEnrollmentRefused": "注册失败。请断开其他 VPN 后重试。",
        "widgetSetupTitle": "需要设置",
        "widgetSetupDetail": "打开应用以允许 VPN",
        "widgetAccessibilityConnect": "将 OpenRung 连接到自动中继",
        "widgetAccessibilityOpen": "打开 OpenRung",
    ]
    // widget-strings:end

    // widget-strings:zh-TW
    static let zhTWTable: [String: String] = [
        "actionConnect": "連線",
        "openContentDescription": "開啟",
        "statusDisconnected": "已中斷",
        "statusPreparing": "正在準備 VPN",
        "statusConnecting": "正在連線",
        "statusConnected": "已連線",
        "statusDisconnecting": "正在中斷",
        "statusFailed": "失敗",
        "relayAuto": "自動中繼",
        "errorAccessDenied": "此裝置的存取權限已被停用，無法連線。請聯絡 OpenRung 支援。",
        "errorEnrollmentRefused": "註冊失敗。請中斷其他 VPN 後重試。",
        "widgetSetupTitle": "需要設定",
        "widgetSetupDetail": "開啟 App 以允許 VPN",
        "widgetAccessibilityConnect": "將 OpenRung 連線到自動中繼",
        "widgetAccessibilityOpen": "開啟 OpenRung",
    ]
    // widget-strings:end

    // widget-strings:fa
    static let faTable: [String: String] = [
        "actionConnect": "اتصال",
        "openContentDescription": "باز کردن",
        "statusDisconnected": "قطع شده",
        "statusPreparing": "در حال آماده‌سازی VPN",
        "statusConnecting": "در حال اتصال",
        "statusConnected": "متصل",
        "statusDisconnecting": "در حال قطع اتصال",
        "statusFailed": "ناموفق",
        "relayAuto": "رله خودکار",
        "errorAccessDenied": "دسترسی این دستگاه غیرفعال شده است و نمی‌تواند وصل شود. با پشتیبانی OpenRung تماس بگیرید.",
        "errorEnrollmentRefused": "ثبت ناموفق بود. VPNهای دیگر را قطع کنید و دوباره تلاش کنید.",
        "widgetSetupTitle": "راه‌اندازی لازم است",
        "widgetSetupDetail": "برای اجازهٔ VPN برنامه را باز کنید",
        "widgetAccessibilityConnect": "اتصال OpenRung به رله خودکار",
        "widgetAccessibilityOpen": "باز کردن OpenRung",
    ]
    // widget-strings:end

    // widget-strings:ru
    static let ruTable: [String: String] = [
        "actionConnect": "ПОДКЛЮЧИТЬ",
        "openContentDescription": "Открыть",
        "statusDisconnected": "Отключено",
        "statusPreparing": "Подготовка VPN",
        "statusConnecting": "Подключение",
        "statusConnected": "Подключено",
        "statusDisconnecting": "Отключение",
        "statusFailed": "Ошибка",
        "relayAuto": "авто-реле",
        "errorAccessDenied": "Доступ для этого устройства отключён, подключение невозможно. Обратитесь в поддержку OpenRung.",
        "errorEnrollmentRefused": "Ошибка регистрации. Отключите другие VPN и повторите.",
        "widgetSetupTitle": "Нужна настройка",
        "widgetSetupDetail": "Откройте приложение, чтобы разрешить VPN",
        "widgetAccessibilityConnect": "Подключить OpenRung к автоматическому реле",
        "widgetAccessibilityOpen": "Открыть OpenRung",
    ]
    // widget-strings:end

    // widget-strings:ar
    static let arTable: [String: String] = [
        "actionConnect": "اتصال",
        "openContentDescription": "فتح",
        "statusDisconnected": "غير متصل",
        "statusPreparing": "جار تجهيز VPN",
        "statusConnecting": "جار الاتصال",
        "statusConnected": "متصل",
        "statusDisconnecting": "جار قطع الاتصال",
        "statusFailed": "فشل",
        "relayAuto": "مرحّل تلقائي",
        "errorAccessDenied": "تم تعطيل وصول هذا الجهاز، لذا لا يمكنه الاتصال. تواصل مع دعم OpenRung.",
        "errorEnrollmentRefused": "فشل التسجيل. افصل شبكات VPN الأخرى وأعد المحاولة.",
        "widgetSetupTitle": "يلزم الإعداد",
        "widgetSetupDetail": "افتح التطبيق للسماح بـ VPN",
        "widgetAccessibilityConnect": "توصيل OpenRung بالمرحّل التلقائي",
        "widgetAccessibilityOpen": "فتح OpenRung",
    ]
    // widget-strings:end

    // widget-strings:tr
    static let trTable: [String: String] = [
        "actionConnect": "BAĞLAN",
        "openContentDescription": "Aç",
        "statusDisconnected": "Bağlı değil",
        "statusPreparing": "VPN hazırlanıyor",
        "statusConnecting": "Bağlanıyor",
        "statusConnected": "Bağlandı",
        "statusDisconnecting": "Bağlantı kesiliyor",
        "statusFailed": "Başarısız",
        "relayAuto": "otomatik röle",
        "errorAccessDenied": "Bu cihazın erişimi devre dışı bırakıldı, bu yüzden bağlanamıyor. OpenRung destek ekibiyle iletişime geçin.",
        "errorEnrollmentRefused": "Kayıt başarısız. Diğer VPN'leri kapatıp tekrar deneyin.",
        "widgetSetupTitle": "Kurulum gerekli",
        "widgetSetupDetail": "VPN izni için uygulamayı açın",
        "widgetAccessibilityConnect": "OpenRung'u otomatik röleye bağla",
        "widgetAccessibilityOpen": "OpenRung'u aç",
    ]
    // widget-strings:end

    // widget-strings:vi
    static let viTable: [String: String] = [
        "actionConnect": "KẾT NỐI",
        "openContentDescription": "Mở",
        "statusDisconnected": "Đã ngắt kết nối",
        "statusPreparing": "Đang chuẩn bị VPN",
        "statusConnecting": "Đang kết nối",
        "statusConnected": "Đã kết nối",
        "statusDisconnecting": "Đang ngắt kết nối",
        "statusFailed": "Thất bại",
        "relayAuto": "relay tự động",
        "errorAccessDenied": "Quyền truy cập của thiết bị này đã bị vô hiệu hóa nên không thể kết nối. Hãy liên hệ bộ phận hỗ trợ OpenRung.",
        "errorEnrollmentRefused": "Đăng ký thất bại. Hãy ngắt các VPN khác và thử lại.",
        "widgetSetupTitle": "Cần thiết lập",
        "widgetSetupDetail": "Mở ứng dụng để cho phép VPN",
        "widgetAccessibilityConnect": "Kết nối OpenRung với relay tự động",
        "widgetAccessibilityOpen": "Mở OpenRung",
    ]
    // widget-strings:end

    // widget-strings:my
    static let myTable: [String: String] = [
        "actionConnect": "ချိတ်ဆက်မည်",
        "openContentDescription": "ဖွင့်ရန်",
        "statusDisconnected": "ချိတ်ဆက်မှု ပြတ်နေသည်",
        "statusPreparing": "VPN ကို ပြင်ဆင်နေသည်",
        "statusConnecting": "ချိတ်ဆက်နေသည်",
        "statusConnected": "ချိတ်ဆက်ပြီး",
        "statusDisconnecting": "ချိတ်ဆက်မှု ဖြုတ်နေသည်",
        "statusFailed": "မအောင်မြင်ပါ",
        "relayAuto": "အလိုအလျောက် relay",
        "errorAccessDenied": "ဤစက်၏ ဝင်ရောက်ခွင့်ကို ပိတ်ထားသဖြင့် ချိတ်ဆက်၍ မရပါ။ OpenRung အကူအညီဌာနကို ဆက်သွယ်ပါ။",
        "errorEnrollmentRefused": "မှတ်ပုံတင်၍ မရပါ။ အခြား VPN များကို ဖြုတ်ပြီး ထပ်စမ်းပါ။",
        "widgetSetupTitle": "ပြင်ဆင်ရန် လိုသည်",
        "widgetSetupDetail": "VPN ခွင့်ပြုရန် အက်ပ်ကို ဖွင့်ပါ",
        "widgetAccessibilityConnect": "OpenRung ကို အလိုအလျောက် relay သို့ ချိတ်ဆက်မည်",
        "widgetAccessibilityOpen": "OpenRung ကို ဖွင့်ရန်",
    ]
    // widget-strings:end

    static func table(for resolvedTag: String) -> [String: String] {
        var merged = enTable
        if let override = tables[resolvedTag] {
            for (key, value) in override where value.isEmpty == false {
                merged[key] = value
            }
        }
        return merged
    }

    static func text(_ key: String, resolvedTag: String) -> String {
        table(for: resolvedTag)[key] ?? key
    }

    static func isRightToLeft(_ resolvedTag: String) -> Bool {
        rightToLeft.contains(resolvedTag)
    }

    /// Drops anything that is not a short BCP-47-ish tag. The widget renders this string; it
    /// must not be able to carry a path, URL, or relay id.
    static func sanitizedLanguageTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= 32 else { return "" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return trimmed
    }

    static func systemLanguageTag(_ localeIdentifier: String = Locale.current.identifier) -> String {
        localeIdentifier.replacingOccurrences(of: "_", with: "-")
    }

    /// Mirrors `resolveLanguage` in `src/i18n/index.tsx`, including the Chinese script split.
    static func resolve(tag: String, systemLocale: String) -> String {
        let requested = (tag.isEmpty ? systemLocale : tag).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = requested.lowercased()
        if let exact = supported.first(where: { $0.lowercased() == lower }) {
            return exact
        }
        if lower.hasPrefix("zh") {
            let traditional = lower.contains("hant")
                || lower.hasSuffix("-tw")
                || lower.hasSuffix("-hk")
                || lower.hasSuffix("-mo")
            return traditional ? "zh-TW" : "zh-CN"
        }
        let primary = lower.split(separator: "-").first.map(String.init) ?? lower
        return supported.first { $0.lowercased() == primary } ?? "en"
    }

    private static let tables: [String: [String: String]] = [
        "en": enTable,
        "zh-CN": zhCNTable,
        "zh-TW": zhTWTable,
        "fa": faTable,
        "ru": ruTable,
        "ar": arTable,
        "tr": trTable,
        "vi": viTable,
        "my": myTable,
    ]
}
