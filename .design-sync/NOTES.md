# design-sync notes — openrung-mobile-app

Repo-specific gotchas for future syncs. This is a **React Native app**, not a
web design-system package — the sync runs an experimental react-native-web
conversion (user-approved 2026-07-07).

- **No repo build.** `cfg.entry` points at `.design-sync/web-entry.ts` (curated
  source re-exports); esbuild compiles the TS directly. There is no dist/ and
  no buildCmd — never run a package build before the converter.
- **react-native → react-native-web** via `cfg.tsconfig`
  (`.design-sync/tsconfig.sync.json` paths). react-native-web + react@19.2.3 +
  react-dom@19.2.3 + playwright are installed in `.ds-sync/node_modules`
  (scratch, gitignored) — `--node-modules .ds-sync/node_modules` serves
  vendorReact too. On a fresh clone: `cd .ds-sync && npm i esbuild ts-morph
  @types/react react@19.2.3 react-dom@19.2.3 react-native-web playwright`.
- **Web shims** (`.design-sync/web-shims/`, aliased in tsconfig.sync.json):
  - `react-native-svg.ts` — re-exports the package's own `elements.web` build
    (the bare index resolves to the native tree under esbuild).
  - `safe-area-context.tsx` — zero-inset provider/hook; never throws without a
    provider (so no cfg.provider is needed).
  - `async-storage.ts` — in-memory map (store hydration only).
  - `maplibre.tsx` — `Marker` renders children in place; only OceanTelemetry
    consumes it (its HUD panel is real code; the map positioning is not).
- **Excluded components**: ExitNodeMap (MapLibre map view), NativeTabs
  (react-native-bottom-tabs native host) — nothing web-renderable to ship.
- **Grouping** comes from `.design-sync/docs/<Name>.md` frontmatter stubs
  (Controls / Panels / Icons); the src tree is flat so path-derived groups
  don't exist. `cfg.docsDir` points there — do NOT let auto-detection bind the
  repo-root `docs/` (release/eng docs, not component docs).
- **Prop contracts** are hand-written in `cfg.dtsPropsFor` (no shipped .d.ts).
  Types inlined from `src/native/types.ts` + `src/model/exitNode.ts` — if
  those interfaces change, update the config bodies to match.
- **Render check** uses the system Chrome via
  `DS_CHROMIUM_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`
  (user chose no chromium download; playwright npm pkg lives in .ds-sync).
- `useStrings()` needs no provider (default context = system-resolved English
  strings), so previews render provider-less by design.

## Preview authoring recipes (wave 1 learnings)

- Review/capture sheets composite cells on WHITE despite the dark live page —
  translucent glass components (OceanTelemetry) and light-on-dark text need an
  explicit dark backdrop div (background '#030604') inside the cell.
- RN `alignSelf` content-hugging is inert inside a plain block div (RNW Views
  stretch): make the preview frame a flex container
  (`display:'flex', justifyContent:'center'` etc.) so components shrink-wrap.
  Seen on ViewModeToggle / MapStatusChip.
- TabBar is `position:absolute, bottom:0` — wrap cells in
  `{position:'relative', width:360, height:84, overflow:'hidden'}`.
- A bare absolute-fill `<Svg>` (EdgeFade) renders at the 300x150 replaced-
  element default on web — scope `<style> svg { width:100%; height:100% }`
  inside the cell frame.
- Components with render-nothing empty branches (RecentsSection) must not get
  empty-state cells — they capture blank and fail grading.
- Icons have no default `color` — always pass one in previews and designs.

## Pipeline quirks fixed in this repo's setup

- **RNW stylesheet vs render check**: react-native-web creates
  `<style id="react-native-stylesheet">` as head's first child, CSSOM-only
  (empty innerHTML). The validate render check selects mount roots via
  `#root, [id^="r"]` — that element matched, sorted first, and flagged every
  preview `[RENDER] root empty` despite perfect renders. Fixed by
  `web-shims/rnw-stylesheet-fix.ts` (imported first by the
  `web-shims/react-native-web.ts` alias target): pre-creates the element with
  a text node at the END of <body> before RNW loads; RNW reuses it. Do not
  remove the fix-import ordering.
- **cardMode column** overrides (cfg.overrides) on the 8 phone-width
  components (ConnectCard, ConsolePanel, MapStatusChip, RelayList,
  ScreenHeader, SettingPanel, TabBar, ViewModeToggle) — 360px story frames
  crop in the product's grid cells (`[GRID_OVERFLOW] wide`).
- Preview pages composite on a white body (harness framing); the dark-body
  tokens.css applies to real designs, not the card screenshots.

## Known render warns

- None as of 2026-07-07 (17/17 clean, 0 thin, 0 variantsIdentical). Any warn
  on a future re-sync is new — investigate before recording here.

## Re-sync risks

- The RNW alias pins `react-native-web/dist/index.js` — an RNW major bump or
  react major bump in the repo can shift behavior; re-verify everything after
  either.
- `dtsPropsFor` duplicates source interfaces by hand — silently stale if
  component props change; grep the diff of `src/components/*.tsx` on re-sync.
- The svg shim's deep import (`react-native-svg/lib/module/elements.web`) is
  an internal path — a react-native-svg upgrade can move it.
- tokens.css duplicates src/theme.ts values by hand — keep in lockstep.
