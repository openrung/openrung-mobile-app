# OpenRung Mobile UI — build conventions

This library is the UI of a React Native VPN app, compiled for the web via
react-native-web. You are designing **phone screens** for a
terminal-green-on-black app where **every text element is monospace**.

## Setup — none required

No provider or wrapper is needed. Components fall back to English strings and
zero safe-area insets on their own. `styles.css` already sets the page to the
app's near-black background (`--or-screen`) with the mono font stack.

## Styling idiom

- **Never restyle the components with CSS classes** — they carry all their
  styles inline (react-native-web). There is no utility-class vocabulary.
- Components that accept a `style` prop (`ConsolePanel`, `RelayList`,
  `MapStatusChip`, `ViewModeToggle`) take a React-Native-style object:
  camelCase keys, unitless numbers (`{ height: 220 }`), NOT class names.
- For **your own layout glue** use plain DOM (`div`/`span`, flex/grid, inline
  styles or CSS) with the theme's custom properties from `styles.css`:
  `--or-screen` `--or-panel` `--or-border-dim` `--or-terminal-green`
  `--or-body-text` `--or-dim-text` `--or-relay-line` `--or-console-error`
  `--or-glass` `--or-glass-dense` `--or-glass-border` `--or-glow`
  `--or-glow-soft` `--or-working` `--or-radius-sm/-md/-lg`
  `--or-tab-bar-height` `--or-edge` `--or-mono`.
- The same values are exported as JS: `palette`, `tokens`, `monoFont`,
  `statusDotColor(status)`.

## Composition gotchas

- Build screens inside a phone frame: `div` ~360×720,
  `position: relative`, `background: var(--or-screen)`, `overflow: hidden`.
- `TabBar` positions itself `absolute; bottom: 0` — it needs that positioned
  phone-frame ancestor.
- Icons (`HomeIcon`, `PowerIcon`, …) are invisible without `color` — pass
  `#65F58A` (terminal green) or `#7DA989` (dim).
- `RecentsSection` renders nothing when `recents` is empty;
  `EdgeFade` is a full-bleed vignette — place it after a map/texture layer
  inside the positioned frame.
- The app's map view and native tabs are not in this library. For a map
  backdrop, use a dark textured `div` + `EdgeFade`; for tabs, use `TabBar`.
- Statuses are string unions — connection: `'disconnected' | 'preparing' |
  'connecting' | 'connected' | 'disconnecting' | 'failed'`; directory:
  `'idle' | 'loading' | 'loaded' | 'failed'` (each component's exact contract
  is in its `.d.ts`).

## Idiomatic example — home screen slice

```jsx
const { ConnectCard, RecentsSection, TabBar } = window.OpenRungUI;

<div style={{ position: 'relative', width: 360, height: 720,
              background: 'var(--or-screen)', overflow: 'hidden' }}>
  <div style={{ position: 'absolute', left: 20, right: 20, bottom: 86,
                display: 'flex', flexDirection: 'column', gap: 14 }}>
    <RecentsSection
      recents={[{ countryCode: 'JP', label: 'Tokyo, Japan', latitude: 35.68, longitude: 139.69 }]}
      onPress={() => {}} />
    <ConnectCard status="connected" relayLabel="Tokyo, Japan"
                 isConnected isWorking={false} onToggle={() => {}} />
  </div>
  <TabBar active="home" onSelect={() => {}} />
</div>
```

Before styling anything, read `styles.css` (tokens) and the component's
`.prompt.md` + `.d.ts`.
