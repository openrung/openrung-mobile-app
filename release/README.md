# release/update-policy.json — the in-app update broadcast channel

This file is the operator-controlled half of the in-app update check (the version numbers are
filled in automatically from package.json at publish time). Editing it and merging to main is how
you broadcast to every installed app — `.github/workflows/update-manifest.yml` republishes the
signed manifest on every change to this file, no app release needed. Full schema, threat model and
serving contract: [docs/UPDATE_MANIFEST.md](../docs/UPDATE_MANIFEST.md).

## Fields

- `min_supported.{android,ios}` — the kill-switch floor (`"x.y.z"`). Clients BELOW this version
  show the full-screen "Update required" screen (with a "Continue anyway" escape hatch for
  self-hosted-broker users). Raise it only for versions that genuinely cannot work anymore
  (protocol breaks), and only after checking the broker's `X-OpenRung-App-Version` telemetry for
  how many users you'd be blocking. CI rejects a floor above the current package.json version.
  Blocking requires a SIGNED manifest — see the signing-key section of docs/UPDATE_MANIFEST.md.
- `promote` — `"silent"` (default: no UI beyond the passive Settings row) or `"notify"` (one
  dismissible home-screen banner per version). Set `notify` when cutting a release users should
  actually install (security fixes, protocol changes); set it back to `silent` afterwards.
- `notice` — `null`, or a freeform broadcast shown as a dismissible card on the home screen:

```json
{
  "id": "2026-07-relay-migration",
  "level": "warn",
  "title": { "en": "Relay network changing", "fa": "…" },
  "body": { "en": "Update before Aug 1 or the app will stop connecting.", "fa": "…" },
  "url": null,
  "expires": "2026-08-01T00:00:00Z"
}
```

  Dismissal is keyed by `id` — to re-show a notice, change the `id`. `title`/`body` are
  `{locale: text}` maps; `en` is required, other app locales (`zh-CN`, `zh-TW`, `fa`, `ru`, `ar`,
  `tr`, `vi`, `my`) fall back to English when missing. `url` (https only) adds a "Learn more"
  button. `expires` (ISO-8601, optional) auto-hides the notice client-side.

Validate locally before pushing:

```bash
node scripts/update-manifest.mjs check
```
