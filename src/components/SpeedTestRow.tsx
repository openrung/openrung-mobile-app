/**
 * Settings row for the volunteer speed test. Runs the download phase (broker
 * speed-test endpoint) then the upload phase (Cloudflare sink) sequentially,
 * with a per-phase subtitle; result shows both directions. Telemetry mirrors
 * production: each completed phase posts its event, failures post
 * speed_test_failed with the phase in test_type — all best-effort and only
 * while a session is active (contract §4).
 */
import React, { useCallback, useState } from 'react';

import { AppConfig } from '../config';
import { useStrings } from '../i18n';
import { OpenRungVpn } from '../native/OpenRungVpn';
import { runSpeedTest, runUploadTest } from '../net/speedTestClient';
import {
  buildSpeedTestCompletedEvent,
  buildSpeedTestFailedEvent,
  buildUploadTestCompletedEvent,
  sendTelemetry,
  type TelemetryEvent,
} from '../net/telemetryClient';
import { RunButton } from './RunButton';
import { SettingPanel } from './SettingPanel';

export interface SpeedTestRowProps {
  isConnected: boolean;
}

type Phase = 'idle' | 'download' | 'upload';

async function postTelemetry(build: () => Promise<TelemetryEvent | null>): Promise<void> {
  try {
    const event = await build();
    if (event != null) {
      await sendTelemetry(AppConfig.TELEMETRY_BROKER_URL, [event]);
    }
  } catch {
    // Telemetry is best-effort; never surfaces in the UI.
  }
}

export function SpeedTestRow({ isConnected }: SpeedTestRowProps): React.JSX.Element {
  const s = useStrings();
  const [phase, setPhase] = useState<Phase>('idle');
  const [result, setResult] = useState<{ downMbps: number; upMbps: number } | null>(null);
  const [error, setError] = useState<string | null>(null);

  const running = phase !== 'idle';

  // Same precedence as production: running > error > result > requires-connection > ready.
  const subtitle = running
    ? phase === 'download'
      ? s.speedTestRunning
      : s.speedTestRunningUpload
    : error != null
      ? s.speedTestError(error)
      : result != null
        ? s.speedTestResultBoth(result.downMbps, result.upMbps)
        : !isConnected
          ? s.speedTestRequiresConnection
          : s.speedTestReady;

  const onRun = useCallback(() => {
    setPhase('download');
    setResult(null);
    setError(null);
    (async () => {
      let currentPhase: 'manual_download' | 'manual_upload' = 'manual_download';
      try {
        const down = await runSpeedTest(AppConfig.TELEMETRY_BROKER_URL);
        await postTelemetry(async () => {
          const identity = await OpenRungVpn.getIdentity();
          return identity.sessionId != null ? buildSpeedTestCompletedEvent(identity, down) : null;
        });

        setPhase('upload');
        currentPhase = 'manual_upload';
        const up = await runUploadTest(AppConfig.SPEEDTEST_UPLOAD_URL);
        await postTelemetry(async () => {
          const identity = await OpenRungVpn.getIdentity();
          return identity.sessionId != null ? buildUploadTestCompletedEvent(identity, up) : null;
        });

        setResult({ downMbps: down.downloadMbps, upMbps: up.uploadMbps });
      } catch (caught) {
        // Mirrors production: message ?: exception simple name for the subtitle,
        // the error type name for the telemetry attribute.
        const errorType =
          caught instanceof Error ? caught.constructor.name || caught.name : 'Error';
        const message = caught instanceof Error ? caught.message || errorType : String(caught);
        setError(message);
        const failedPhase = currentPhase;
        await postTelemetry(async () => {
          const identity = await OpenRungVpn.getIdentity();
          return identity.sessionId != null
            ? buildSpeedTestFailedEvent(identity, errorType, failedPhase)
            : null;
        });
      } finally {
        setPhase('idle');
      }
    })();
  }, []);

  return (
    <SettingPanel
      title={s.speedTestSettingTitle}
      subtitle={subtitle}
      trailing={
        <RunButton label={s.speedTestAction} onPress={onRun} enabled={isConnected && !running} />
      }
    />
  );
}
