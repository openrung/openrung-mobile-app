// Web shim for react-native-safe-area-context. Unlike the real package,
// useSafeAreaInsets never throws without a provider — previews and designs
// render with zero insets by default; wrap in SafeAreaProvider with
// `initialInsets` to simulate a device notch/home-indicator.
import React, { createContext, useContext } from 'react';
import { View } from 'react-native';

export interface EdgeInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

const ZERO_INSETS: EdgeInsets = { top: 0, right: 0, bottom: 0, left: 0 };

export const SafeAreaInsetsContext = createContext<EdgeInsets>(ZERO_INSETS);

export function SafeAreaProvider({
  children,
  initialInsets,
}: {
  children?: React.ReactNode;
  initialInsets?: EdgeInsets;
}): React.JSX.Element {
  return (
    <SafeAreaInsetsContext.Provider value={initialInsets ?? ZERO_INSETS}>
      {children}
    </SafeAreaInsetsContext.Provider>
  );
}

export function useSafeAreaInsets(): EdgeInsets {
  return useContext(SafeAreaInsetsContext);
}

export function useSafeAreaFrame(): { x: number; y: number; width: number; height: number } {
  return { x: 0, y: 0, width: 390, height: 844 };
}

export const SafeAreaView = View;
