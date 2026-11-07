/// <reference types="node" />
jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => undefined),
    removeItem: jest.fn(async () => undefined),
  },
}));

import fs from 'node:fs';
import path from 'node:path';

import { NativeModules, Platform } from 'react-native';

import { resolveLanguage, stringsForTag } from '../../src/i18n';
import { publishWidgetLanguage } from '../../src/native/widgetLanguage';

const root = path.resolve(__dirname, '../..');
const policySource = fs.readFileSync(
  path.join(root, 'ios/Shared/WidgetConnectPolicy.swift'),
  'utf8',
);
const urlSource = fs.readFileSync(path.join(root, 'ios/Shared/WidgetConnectURL.swift'), 'utf8');
const stringsSource = fs.readFileSync(path.join(root, 'ios/Shared/WidgetStrings.swift'), 'utf8');

const sharedKeys = [
  'actionConnect',
  'openContentDescription',
  'statusDisconnected',
  'statusPreparing',
  'statusConnecting',
  'statusConnected',
  'statusDisconnecting',
  'statusFailed',
  'relayAuto',
  'errorAccessDenied',
  'errorEnrollmentRefused',
] as const;

const widgetOnlyKeys = [
  'widgetSetupTitle',
  'widgetSetupDetail',
  'widgetAccessibilityConnect',
  'widgetAccessibilityOpen',
] as const;

function swiftTables(): Record<string, Record<string, string>> {
  const tables: Record<string, Record<string, string>> = {};
  const pattern = /\/\/ widget-strings:([^\n]+)\n([\s\S]*?)\/\/ widget-strings:end/g;
  for (const match of stringsSource.matchAll(pattern)) {
    const tag = match[1].trim();
    const body = match[2];
    const entries: Record<string, string> = {};
    for (const line of body.matchAll(/"([^"]+)": "((?:\\.|[^"\\])*)"/g)) {
      entries[line[1]] = line[2].replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    tables[tag] = entries;
  }
  return tables;
}

describe('widget handoff contract', () => {
  const tables = swiftTables();

  test('widget copy matches the app strings for every shipped language', () => {
    const tags = ['en', 'zh-CN', 'zh-TW', 'fa', 'ru', 'ar', 'tr', 'vi', 'my'];
    expect(Object.keys(tables).sort()).toEqual([...tags].sort());
    for (const tag of tags) {
      const strings = stringsForTag(tag) as unknown as Record<string, string>;
      for (const key of sharedKeys) {
        expect(tables[tag][key]).toBe(strings[key]);
      }
      for (const key of widgetOnlyKeys) {
        expect(tables[tag][key]?.length).toBeGreaterThan(0);
      }
    }
  });

  test('language resolution cases match the shell and the Swift source', () => {
    expect(resolveLanguage('fa-IR')).toBe('fa');
    expect(resolveLanguage('vi-VN')).toBe('vi');
    expect(resolveLanguage('zh-HK')).toBe('zh-TW');
    expect(resolveLanguage('zh-Hans')).toBe('zh-CN');
    expect(resolveLanguage('pt-BR')).toBe('en');
    expect(policySource).toContain('requestTTLMillis: Int64 = 90_000');
    expect(policySource).toContain('futureSkewMillis: Int64 = 60_000');
    expect(policySource).toContain('duplicateStartSuppressionMillis: Int64 = 1_500');
    expect(policySource).toContain('case .disconnected, .invalid:');
    expect(policySource).toContain('case .connecting, .connected, .reasserting, .disconnecting:');
    expect(stringsSource).toContain('lower.hasSuffix("-tw")');
    expect(stringsSource).toContain('lower.hasSuffix("-hk")');
    expect(stringsSource).toContain('lower.hasSuffix("-mo")');
    expect(stringsSource).toContain('lower.contains("hant")');
  });

  test('the wake URL cannot carry a relay, country, user, or query', () => {
    expect(urlSource).toContain('url.query == nil');
    expect(urlSource).toContain('url.fragment == nil');
    expect(urlSource).toContain('url.user == nil');
    expect(urlSource).toContain('url.password == nil');
    expect(urlSource).toContain('url.port == nil');
    expect(urlSource).toContain('case "open"');
    expect(urlSource).toContain('case "connect-auto"');
    expect(urlSource).not.toContain('target_country');
    expect(urlSource).not.toContain('target_relay');
  });

  test('publishWidgetLanguage is iOS-only and optional', () => {
    const setLanguageTag = jest.fn();
    (NativeModules as { OpenRungWidget?: { setLanguageTag: (tag: string) => void } }).OpenRungWidget =
      { setLanguageTag };
    const platform = Platform.OS;
    Object.defineProperty(Platform, 'OS', { configurable: true, get: () => 'ios' });
    publishWidgetLanguage('fa');
    expect(setLanguageTag).toHaveBeenCalledWith('fa');

    setLanguageTag.mockClear();
    Object.defineProperty(Platform, 'OS', { configurable: true, get: () => 'android' });
    publishWidgetLanguage('fa');
    expect(setLanguageTag).not.toHaveBeenCalled();

    delete (NativeModules as { OpenRungWidget?: unknown }).OpenRungWidget;
    Object.defineProperty(Platform, 'OS', { configurable: true, get: () => 'ios' });
    expect(() => publishWidgetLanguage('en')).not.toThrow();
    Object.defineProperty(Platform, 'OS', { configurable: true, get: () => platform });
  });
});
