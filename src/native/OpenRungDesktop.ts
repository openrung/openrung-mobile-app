import { NativeModules, Platform } from 'react-native';

/**
 * The desktop client (macOS / Windows / Linux) runs this same app through react-native-web inside
 * a webview shell, with the Go client engine behind the `OpenRungVpn` / `OpenRungBroker` bridge
 * contract. `OpenRungDesktop` is the part of that host with no mobile counterpart.
 */

/**
 * The loopback proxy the desktop client serves while connected. Desktop has no OS-level VPN
 * profile: the system proxy points here, and a terminal session can opt in through the generated
 * shell commands.
 */
export interface DesktopProxyInfo {
  endpoint: string; // host:port
  persistenceWarning: string | null; // the endpoint works but may change on the next launch
  shellIntegration: boolean; // sourceable POSIX shell commands are available on this OS
  shellIntegrationError: string | null; // generating them failed; the endpoint stays usable
  enableCommand: string; // routes the current shell through the proxy
  disableCommand: string; // restores that shell's previous proxy variables
}

/**
 * How the desktop client captures traffic. `proxy` is the loopback proxy above; `tun` routes the
 * whole device through a TUN interface, which the host can offer only where it can obtain the
 * rights to create one.
 */
export type DesktopCaptureMode = 'proxy' | 'tun';

export interface DesktopTunnelMode {
  mode: DesktopCaptureMode; // the mode connects use
  available: boolean; // TUN mode can be selected on this system
  requiresRestart: boolean; // selecting it restarts the client with administrator rights
}

export interface OpenRungDesktopModule {
  /** The desktop client's own version; the mobile package version does not describe it. */
  appVersion: string;
  getProxyInfo(): Promise<DesktopProxyInfo>;
  /** Absent, with `setTunnelMode`, on a host that predates the capture mode: proxy only. */
  getTunnelMode?(): Promise<DesktopTunnelMode>;
  /**
   * Selects the mode for later connects; rejects while a tunnel is up. Where `requiresRestart`
   * was reported, selecting `tun` restarts the client and the promise may never settle. A
   * declined restart rejects and leaves proxy mode in place.
   */
  setTunnelMode?(mode: DesktopCaptureMode): Promise<void>;
  /** Clipboard write through the host (a webview may not expose the browser clipboard API). */
  copyText(text: string): Promise<void>;
}

/** True in the desktop client. Mobile-only features key off this, never off the module below. */
export const isDesktop = Platform.OS === 'web';

/** The desktop host module, or null on mobile and in a plain browser preview without the host. */
export const OpenRungDesktop: OpenRungDesktopModule | null = isDesktop
  ? (((NativeModules as Record<string, unknown>).OpenRungDesktop as
      | OpenRungDesktopModule
      | null
      | undefined) ?? null)
  : null;
