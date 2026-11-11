/**
 * Session uptime in the connect card: how long the tunnel has been connected, as a ticking
 * hh:mm:ss clock counted from the store's `connectedAtMs` stamp.
 */
import React, { useEffect, useState } from 'react';
import { StyleProp, Text, TextStyle } from 'react-native';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

const MAX_UPTIME_SECONDS = 99 * 3600 + 59 * 60 + 59; // display pins at 99:59:59

/** hh:mm:ss, clamped at zero (clock skew) and at 99:59:59 so the column never widens. */
export function formatUptime(elapsedMs: number): string {
  const totalSeconds = Math.min(Math.max(0, Math.floor(elapsedMs / 1000)), MAX_UPTIME_SECONDS);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return `${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
}

export interface SessionTimerProps {
  /** Store stamp of the moment the tunnel entered 'connected'. */
  connectedAtMs: number;
  style?: StyleProp<TextStyle>;
}

/** Its own component so the once-a-second tick re-renders this text and nothing around it. */
export function SessionTimer({ connectedAtMs, style }: SessionTimerProps): React.JSX.Element {
  const [nowMs, setNowMs] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  return (
    // A clock that announced itself every second would drown out a screen reader.
    <Text style={style} numberOfLines={1} accessibilityElementsHidden importantForAccessibility="no">
      {formatUptime(nowMs - connectedAtMs)}
    </Text>
  );
}
