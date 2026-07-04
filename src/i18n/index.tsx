import React, { createContext, useContext, useEffect, useMemo } from 'react';
import type { ConnectionStatus } from '../native/types';
import { hydrateLanguage, setLanguageTag, useAppState } from '../state/store';
import { ar } from './strings/ar';
import { en } from './strings/en';
import type { Strings } from './strings/en';
import { fa } from './strings/fa';
import { my } from './strings/my';
import { ru } from './strings/ru';
import { tr } from './strings/tr';
import { vi } from './strings/vi';
import { zhCN } from './strings/zh-CN';
import { zhTW } from './strings/zh-TW';

export type { Strings };

/**
 * Language selection, mirroring the production per-app-locale picker. Tag '' = system default.
 *
 * RTL note (contract §8): switching to fa/ar in-app changes the strings immediately but does NOT
 * relayout the app right-to-left without an app restart — same as documented for the prototype.
 */

export const SUPPORTED_TAGS = ['en', 'zh-CN', 'zh-TW', 'fa', 'ru', 'ar', 'tr', 'vi', 'my'] as const;
export type SupportedTag = (typeof SUPPORTED_TAGS)[number];

const OVERRIDES: Record<SupportedTag, Partial<Strings>> = {
  en: {},
  'zh-CN': zhCN,
  'zh-TW': zhTW,
  fa,
  ru,
  ar,
  tr,
  vi,
  my,
};

/**
 * Picker options in the exact production order: System default first, then the nine languages.
 * `label` reads the (locale-appropriate) option name out of the active strings.
 */
export interface LanguageOption {
  tag: '' | SupportedTag;
  label: (strings: Strings) => string;
}

export const languageOptions: LanguageOption[] = [
  { tag: '', label: strings => strings.languageSystem },
  { tag: 'en', label: strings => strings.languageEnglish },
  { tag: 'zh-CN', label: strings => strings.languageSimplifiedChinese },
  { tag: 'zh-TW', label: strings => strings.languageTraditionalChinese },
  { tag: 'fa', label: strings => strings.languagePersian },
  { tag: 'ru', label: strings => strings.languageRussian },
  { tag: 'ar', label: strings => strings.languageArabic },
  { tag: 'tr', label: strings => strings.languageTurkish },
  { tag: 'vi', label: strings => strings.languageVietnamese },
  { tag: 'my', label: strings => strings.languageBurmese },
];

/** Best-effort system locale via Intl (Hermes ships Intl on both platforms); fallback 'en'. */
function systemLocale(): string {
  try {
    const locale = Intl.DateTimeFormat().resolvedOptions().locale;
    return typeof locale === 'string' && locale.length > 0 ? locale : 'en';
  } catch {
    return 'en';
  }
}

/** Resolves a stored tag ('' = system) to one of the supported tags (fallback 'en'). */
export function resolveLanguage(tag: string): SupportedTag {
  const requested = (tag || systemLocale()).trim();
  const lower = requested.toLowerCase();
  const exact = SUPPORTED_TAGS.find(supported => supported.toLowerCase() === lower);
  if (exact) {
    return exact;
  }
  if (lower.startsWith('zh')) {
    // Match Android resource resolution: Traditional for Hant/TW/HK/MO, Simplified otherwise.
    const traditional =
      lower.includes('hant') ||
      lower.endsWith('-tw') ||
      lower.endsWith('-hk') ||
      lower.endsWith('-mo');
    return traditional ? 'zh-TW' : 'zh-CN';
  }
  const primary = lower.split('-')[0];
  const byPrimary = SUPPORTED_TAGS.find(supported => supported.toLowerCase() === primary);
  return byPrimary ?? 'en';
}

/** Full string table for a stored tag, with English as the fallback for missing keys. */
export function stringsForTag(tag: string): Strings {
  const resolved = resolveLanguage(tag);
  return { ...en, ...OVERRIDES[resolved] };
}

/** Localized label for a connection status (production `ConnectionStatus.labelResId`). */
export function statusLabel(strings: Strings, status: ConnectionStatus): string {
  switch (status) {
    case 'disconnected':
      return strings.statusDisconnected;
    case 'preparing':
      return strings.statusPreparing;
    case 'connecting':
      return strings.statusConnecting;
    case 'connected':
      return strings.statusConnected;
    case 'disconnecting':
      return strings.statusDisconnecting;
    case 'failed':
      return strings.statusFailed;
  }
}

interface LanguageContextValue {
  strings: Strings;
  /** The stored tag: '' = system default. */
  languageTag: string;
  setLanguage: (tag: string) => void;
}

const LanguageContext = createContext<LanguageContextValue>({
  strings: stringsForTag(''),
  languageTag: '',
  setLanguage: setLanguageTag,
});

export function LanguageProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const { languageTag } = useAppState();

  useEffect(() => {
    // Load the persisted selection (AsyncStorage key 'openrung.language') once on mount.
    hydrateLanguage();
  }, []);

  const value = useMemo<LanguageContextValue>(
    () => ({
      strings: stringsForTag(languageTag),
      languageTag,
      setLanguage: setLanguageTag,
    }),
    [languageTag],
  );

  return <LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>;
}

/** Active string table (falls back to system-resolved strings without a provider). */
export function useStrings(): Strings {
  return useContext(LanguageContext).strings;
}

/** Full language context: strings + current tag + setter. */
export function useLanguage(): LanguageContextValue {
  return useContext(LanguageContext);
}
