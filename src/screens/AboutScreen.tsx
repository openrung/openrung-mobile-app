/**
 * About us tab: wordmark hero with version pill and project manifesto, followed
 * by privacy / open-source-licenses panels and icon-only links to the website
 * and social profiles. Version and licensing live here so the Settings tab
 * stays purely operational.
 */
import React, { useCallback } from 'react';
import { Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SettingPanel } from '../components/SettingPanel';
import {
  BlueskyIcon,
  GitHubIcon,
  InstagramIcon,
  TelegramIcon,
  ThreadsIcon,
  WebsiteIcon,
  XIcon,
} from '../components/SocialIcons';
import { APP_VERSION, AppConfig } from '../config';
import { useStrings } from '../i18n';
import { monoFont, palette, tokens } from '../theme';

export interface AboutScreenProps {
  onOpenLicenses: () => void;
}

const SOCIAL_LINKS = [
  {
    label: 'OpenRung website',
    url: AppConfig.WEBSITE_URL,
    color: palette.terminalGreen,
    Icon: WebsiteIcon,
  },
  {
    label: 'OpenRung on GitHub',
    url: AppConfig.GITHUB_URL,
    color: palette.bodyText,
    Icon: GitHubIcon,
  },
  { label: 'OpenRung on X', url: AppConfig.X_URL, color: palette.bodyText, Icon: XIcon },
  {
    label: 'OpenRung on Threads',
    url: AppConfig.THREADS_URL,
    color: palette.bodyText,
    Icon: ThreadsIcon,
  },
  {
    label: 'OpenRung on Bluesky',
    url: AppConfig.BLUESKY_URL,
    color: '#1185FE',
    Icon: BlueskyIcon,
  },
  {
    label: 'OpenRung on Instagram',
    url: AppConfig.INSTAGRAM_URL,
    color: '#E4405F',
    Icon: InstagramIcon,
  },
  {
    label: 'OpenRung Telegram bot',
    url: AppConfig.TELEGRAM_URL,
    color: '#26A5E4',
    Icon: TelegramIcon,
  },
] as const;

export function AboutScreen({ onOpenLicenses }: AboutScreenProps): React.JSX.Element {
  const s = useStrings();
  const insets = useSafeAreaInsets();

  const onOpenPrivacy = useCallback(() => {
    Linking.openURL(AppConfig.PRIVACY_URL).catch(() => {
      // Ignore: no browser available.
    });
  }, []);

  const onOpenSocial = useCallback((url: string) => {
    Linking.openURL(url).catch(() => {
      // Ignore: no browser or matching app available.
    });
  }, []);

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={[
        styles.content,
        {
          paddingTop: insets.top + 24,
          paddingBottom: tokens.tabBarHeight + insets.bottom + 24,
        },
      ]}
    >
      <Text style={styles.title}>{s.aboutTitle}</Text>

      <View style={styles.hero}>
        <View style={styles.heroRow}>
          <Text style={styles.heroWordmark}>{s.appName}</Text>
          <View style={styles.versionPill}>
            <Text style={styles.versionText}>v{APP_VERSION}</Text>
          </View>
        </View>
        <Text style={styles.heroTagline}>{s.homeTagline}</Text>
        <Text style={styles.missionLead}>{s.aboutMissionLead}</Text>
        <Text style={styles.mission}>{s.aboutMissionBody}</Text>
      </View>

      <Text style={styles.sectionHeader}>{s.aboutLegalHeader.toUpperCase()}</Text>
      <SettingPanel
        title={s.privacyPolicyTitle}
        subtitle={s.privacyPolicySubtitle}
        onPress={onOpenPrivacy}
      />
      <SettingPanel
        title={s.licensesSettingTitle}
        subtitle={s.licensesSettingSubtitle}
        onPress={onOpenLicenses}
      />

      <Text style={styles.sectionHeader}>{s.aboutFollowHeader.toUpperCase()}</Text>
      <View style={styles.socialRow}>
        {SOCIAL_LINKS.map(({ label, url, color, Icon }) => (
          <Pressable
            key={url}
            accessibilityRole="link"
            accessibilityLabel={label}
            hitSlop={6}
            onPress={() => onOpenSocial(url)}
            style={({ pressed }) => [styles.socialButton, pressed && styles.socialButtonPressed]}
          >
            <Icon color={color} size={20} />
          </Pressable>
        ))}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: palette.screen,
  },
  content: {
    paddingHorizontal: tokens.edge,
    gap: 14,
  },
  title: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 26,
    marginBottom: 6,
  },
  hero: {
    borderRadius: tokens.radiusLg,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
    padding: 16,
    gap: 4,
  },
  heroRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  heroWordmark: {
    color: palette.terminalGreen,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 22,
    textShadowColor: tokens.glowSoft,
    textShadowRadius: 10,
  },
  versionPill: {
    borderRadius: 999,
    borderWidth: 1,
    borderColor: palette.borderDim,
    backgroundColor: palette.fabBackground,
    paddingHorizontal: 10,
    paddingVertical: 3,
  },
  versionText: {
    color: palette.relayLine,
    fontFamily: monoFont,
    fontSize: 11,
  },
  heroTagline: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontSize: 11,
    letterSpacing: 1.2,
  },
  missionLead: {
    marginTop: 10,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 14,
    lineHeight: 20,
  },
  mission: {
    marginTop: 2,
    color: palette.bodyText,
    fontFamily: monoFont,
    fontSize: 12,
    lineHeight: 18,
  },
  sectionHeader: {
    color: palette.dimText,
    fontFamily: monoFont,
    fontWeight: 'bold',
    fontSize: 11,
    letterSpacing: 1.5,
    marginTop: 8,
  },
  socialRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  socialButton: {
    width: 34,
    height: 34,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: tokens.radiusSm,
    backgroundColor: palette.panel,
    borderWidth: 1,
    borderColor: palette.borderDim,
  },
  socialButtonPressed: {
    opacity: 0.6,
  },
});
