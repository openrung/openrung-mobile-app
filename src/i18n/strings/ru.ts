import type { Strings } from './en';

/** Ported from `res/values-ru/strings.xml`; missing keys fall back to English. */
export const ru: Partial<Strings> = {
  appName: 'OpenRung',
  mainTitle: 'openrung://mobile-client',
  statusFormat: (status: string) => `статус = ${status}`,
  relayFormat: (relay: string) => `ретранслятор = ${relay}`,
  relayLocationUnknown: 'Неизвестное местоположение',
  actionConnect: 'ПОДКЛЮЧИТЬ',
  actionDisconnect: 'ОТКЛЮЧИТЬ',
  readyLog: 'готово. нажмите «подключить», чтобы пройти через ретранслятор.',
  logLineFormat: (line: string) => `> ${line}`,
  errorLineFormat: (error: string) => `! ${error}`,
  trafficRouteConnected:
    'маршрут трафика: устройство -> OpenRung VPN -> ретранслятор',
  trafficRouteDisconnected: 'vpn работает fail-closed: нет ретранслятора, нет подключения.',
  settingsContentDescription: 'Открыть настройки',
  settingsTitle: 'Настройки',
  backContentDescription: 'Назад',
  languageSettingTitle: 'Язык',
  languageSettingSubtitle: 'Используйте системный язык или выберите язык для OpenRung.',
  versionSettingTitle: 'Версия',
  languageSystem: 'Как в системе',
  languageEnglish: 'English',
  languageSimplifiedChinese: '简体中文',
  languageTraditionalChinese: '繁體中文',
  languagePersian: 'فارسی',
  languageRussian: 'Русский',
  languageArabic: 'العربية',
  languageTurkish: 'Türkçe',
  languageVietnamese: 'Tiếng Việt',
  languageBurmese: 'မြန်မာ',
  statusDisconnected: 'Отключено',
  statusPreparing: 'Подготовка VPN',
  statusConnecting: 'Подключение',
  statusConnected: 'Подключено',
  statusDisconnecting: 'Отключение',
  statusFailed: 'Ошибка',

  // Redesigned shell (tabs / about / section headers).
  tabHome: 'Главная',
  tabSettings: 'Настройки',
  tabAbout: 'О нас',
  aboutTitle: 'О нас',
  relayAuto: 'авто-реле',
  settingsGeneralHeader: 'Основные',
  settingsDiagnosticsHeader: 'Диагностика',

  // Ocean telemetry panel (map view).
  telemetryNetworkHeader: 'СЕТЬ',
  telemetryLinkHeader: 'КАНАЛ',
  telemetryRelaysLabel: 'реле',
  telemetryLocationsLabel: 'локации',
  telemetryCountriesLabel: 'страны',
  telemetryUptimeLabel: 'аптайм',

  // Content description (open action).
  openContentDescription: 'Открыть',

  // Relay speed test (diagnostics).
  speedTestSettingTitle: 'Тест скорости ретранслятора',
  speedTestReady: 'Загрузить 10 MB через активный ретранслятор и показать результат.',
  speedTestRequiresConnection: 'Перед запуском теста скорости подключитесь к ретранслятору.',
  speedTestRunning: 'Проверка скорости загрузки через ретранслятор…',
  speedTestResult: (mbps: number) => `Скорость загрузки: ${mbps.toFixed(1)} Mbps`,
  speedTestError: (error: string) => `Ошибка теста скорости: ${error}`,
  speedTestAction: 'ЗАПУСК',

  // Map view (exit-node overview).
  mapContentDescription: 'Карта доступных выходных узлов в Азиатско-Тихоокеанском регионе',
  mapLoading: 'поиск доступных выходных узлов…',
  mapFailed: 'не удалось загрузить выходные узлы — нажмите, чтобы повторить',
  mapNodesAvailable: (count: number) => `доступно локаций: ${count}`,
  mapNoNodes: 'сейчас нет доступных выходных узлов',

  // Recents, view toggle & list view.
  recentsLabel: 'Недавние',
  recentsEmpty: 'Пока нет недавних локаций.',
  viewToggleMap: 'Карта',
  viewToggleList: 'Список',
  listContentDescription: 'Список доступных выходных узлов',
  listRelayCount: (count: number) => (count === 1 ? '1 реле' : `${count} реле`),

  // Debug console (diagnostics).
  debugSettingTitle: 'Отладка',
  debugSettingSubtitle: 'Консоль подключения и диагностика.',
  debugTitle: 'Консоль отладки',

  // Open-source licenses.
  licensesSettingTitle: 'Лицензии с открытым исходным кодом',
  licensesSettingSubtitle: 'Лицензии и атрибуция для включённого ПО.',
  licensesTitle: 'Лицензии с открытым исходным кодом',
  licensesIntro:
    'OpenRung — свободное программное обеспечение под лицензией GPL-3.0-or-later, поскольку использует sing-box. Полный соответствующий исходный код этой сборки доступен по ссылке ниже.',
  licensesSourceTitle: 'Исходный код',
  licensesFullTextTitle: 'Полные тексты лицензий',
  licensesFullTextSubtitle: 'GNU GPL-3.0 и уведомления третьих сторон.',
  licensesComponentsHeader: 'Компоненты',
  shareApkTitle: 'Поделиться OpenRung офлайн',
  shareApkSubtitle:
    'Отправьте этот APK на ближайший Android-телефон без интернета.',
  shareApkErrorTitle: 'Не удалось поделиться OpenRung',
  shareApkErrorBody:
    'Не удалось поделиться APK. Оставьте OpenRung открытым и повторите попытку.',
  shareApkSplitInstallError:
    'Эта копия установлена из нескольких APK и не может быть безопасно передана. Установите отдельный APK OpenRung, чтобы использовать офлайн-обмен.',

  // Home overlay / about screen.
  homeTagline: 'сеть ретрансляторов',
  aboutMissionBody:
    'OpenRung направляет ваш трафик через ретрансляторы по всему миру, сохраняя открытый интернет доступным, когда сети фильтруются. Аккаунт не нужен, рекламы нет. Во время раннего тестирования OpenRung собирает диагностические метаданные соединений для повышения надёжности.',
  aboutHowHeader: 'Как это работает',
  aboutProjectHeader: 'Проект',
  aboutHow1Title: 'Операторы ретрансляторов предоставляют ресурсы',
  aboutHow1Body:
    'Фонд OpenRung и волонтёры сообщества запускают ретрансляторы и регистрируют их в сети.',
  aboutHow2Title: 'Брокер находит ваш ретранслятор',
  aboutHow2Body:
    'Когда вы подключаетесь, брокер передаёт вашему устройству короткий список работающих ретрансляторов, и приложение выбирает первый ответивший.',
  aboutHow3Title: 'Трафик идёт по зашифрованному туннелю',
  aboutHow3Body:
    'Всё проходит через туннель VLESS/REALITY, который выглядит как обычный TLS, а VPN работает fail-closed: нет ретранслятора, нет трафика.',
  aboutFootnote:
    'OpenRung — свободное программное обеспечение (GPL-3.0-or-later). Создано волонтёрами для всех.',
};
