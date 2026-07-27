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
  privacyPolicyTitle: 'Политика конфиденциальности',
  privacyPolicySubtitle:
    'Как OpenRung обрабатывает диагностические данные бета-версии и персональную информацию.',
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
  shareTestFlightTitle: 'Поделиться OpenRung',
  shareTestFlightSubtitle:
    'Отправьте ссылку TestFlight, чтобы другие могли установить iOS-бету.',
  shareTestFlightMessage: 'Присоединяйтесь к бете OpenRung в TestFlight:',
  shareTestFlightErrorTitle: 'Не удалось поделиться OpenRung',
  shareTestFlightErrorBody:
    'Не удалось поделиться ссылкой TestFlight. Попробуйте ещё раз.',

  // Home overlay / about screen.
  homeTagline: 'сеть ретрансляторов',
  aboutMissionLead: 'Мы верим, что доступ в интернет — это право, а не привилегия',
  aboutMissionBody:
    'и не разменная монета в руках власть имущих. Право на информацию заложено в самой человеческой природе, и никакой файрвол не должен стирать его. Но сегодня миллиарды людей живут за стенами, возведёнными, чтобы не впускать информацию и не выпускать молчание; там поиск Google возвращает ошибку 404, вопрос может быть опасным, а любопытство заканчивается на заблокированной странице.\n\nOpenRung существует, чтобы изменить это.\n\nМы строим лестницу через эти стены. Обычные люди по всему миру делятся своим подключением, чтобы человек по другую сторону файрвола мог выйти в открытый интернет.\n\nИнформация — это сила, и эта сила принадлежит нам, а не тем, кто хочет её у нас отнять.',
  aboutLegalHeader: 'Правовая информация',
  aboutFollowHeader: 'Подписывайтесь',

  // --- Split tunneling (settings row + screen + Android app picker) ---
  splitTunnelSettingTitle: 'Раздельное туннелирование',
  splitTunnelSettingSubtitleOn: 'Включено — выбранный трафик идёт мимо ретранслятора.',
  splitTunnelSettingSubtitleOff: 'Выключено — весь трафик идёт через ретранслятор.',
  splitTunnelHeader: 'Раздельное туннелирование',
  splitTunnelMasterTitle: 'Раздельное туннелирование',
  splitTunnelMasterSubtitle: 'Отправлять выбранный трафик мимо туннеля ретранслятора.',
  splitTunnelBypassHeader: 'Обход',
  splitTunnelLanTitle: 'Локальная сеть',
  splitTunnelLanSubtitle:
    'Прямой доступ к принтерам, телевизорам и другим устройствам локальной сети.',
  splitTunnelIranTitle: 'Иранские сайты и приложения',
  splitTunnelIranSubtitle: 'Направлять иранские сервисы напрямую, на полной скорости.',
  splitTunnelChinaTitle: 'Китайские сайты и приложения',
  splitTunnelChinaSubtitle: 'Направлять китайские сервисы напрямую, на полной скорости.',
  splitTunnelAppsHeader: 'Приложения',
  splitTunnelAppsTitle: 'Приложения в обход',
  splitTunnelAppsSubtitle: (count: number) => `приложений в обход VPN: ${count}`,
  splitTunnelAppPickerTitle: 'Приложения в обход',
  splitTunnelAppPickerLoading: 'загрузка установленных приложений…',
  splitTunnelAppPickerEmpty: 'запускаемых приложений не найдено.',
  splitTunnelAppPickerClose: 'ЗАКРЫТЬ',
  splitTunnelApplyHint:
    'изменения применяются сразу; туннель переподключается на несколько секунд.',

  // --- In-app update check (manifest banner / blocking screen / broadcast notice) ---
  updateRequiredTitle: 'Требуется обновление',
  updateRequiredBody:
    'Эта версия OpenRung больше не может подключаться к сети ретрансляторов. Установите последний выпуск, чтобы продолжить пользоваться приложением.',
  updateVersionTransition: (current: string, latest: string) => `v${current} -> v${latest}`,
  updateActionNow: 'ОБНОВИТЬ',
  updateActionLater: 'Позже',
  updateContinueAnyway: 'Всё равно продолжить',
  updateBannerTitle: 'Доступно обновление',
  updateBannerBody: (latest: string) =>
    `Версия ${latest} содержит важные исправления. Обновитесь при возможности.`,
  updateSettingTitle: 'Доступно обновление',
  updateSettingSubtitle: (current: string, latest: string) =>
    `У вас v${current}; вышла v${latest}. Нажмите, чтобы установить.`,
  noticeDismiss: 'Закрыть',
  noticeLearnMore: 'Подробнее',
};
