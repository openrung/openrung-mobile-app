# In-app update manifest

The update check exists because of a hard lesson: a breaking change once shipped and old app
versions simply stopped working, with **no way to tell users to update**. The manifest is the
standing channel that fixes that for every version from now on. It is one mechanism serving three
features: the update check, the kill-switch floor (`min_supported`), and freeform operator
broadcasts (`notice`). Checking happens silently on every cold start and app foreground (throttled
to 6h); what the user *sees* is decided entirely by the manifest contents — so routine daily
releases produce zero prompts.

Client pieces: `src/net/updateManifestClient.ts` (fetch + verify + decode),
`src/model/updateStatus.ts` (tier derivation), `src/state/updateCheck.ts` (orchestration),
`src/screens/UpdateRequiredScreen.tsx` + `src/components/UpdateBanner.tsx` (UI).
Publishing pieces: `release/update-policy.json` (operator knobs, see `release/README.md`),
`scripts/update-manifest.mjs` (generate/sign/check), and `.github/workflows/update-manifest.yml` —
the **one** publisher, invoked by policy edits on main, by manual dispatch, and (via
`workflow_call`) by `release.yml` after each release. Every invocation runs behind a shared
concurrency mutex and generates from **latest main**, so publishers can never race each other and
a stale checkout can never be the source; `release.yml` itself only fail-fast-validates the
policy/seed and never generates the published manifest.

## The forever contract

Every shipped client keeps checking these URLs with this schema for as long as it is installed —
that is the entire point. Therefore:

- **URLs are immutable.** `AppConfig.UPDATE_MANIFEST_URLS`:
  1. `https://broker.openrung.org/api/v1/app-manifest` (Cloudflare front — censorship-resistant)
  2. `https://d2r7mdpyevvs1m.cloudfront.net/api/v1/app-manifest` (independent second front)
  3. `https://github.com/openrung/openrung-mobile-app/releases/latest/download/update-manifest.json`
     (zero-infrastructure fallback; works from the first release, but github.com is unreliable in
     several target regions)
  Candidates are walked in order, fail-open, preferring the first **verified** envelope — an
  unsigned-but-decodable copy is kept only as a fallback, so one front serving a sig-stripped
  copy cannot shadow the signed copy on a later front. New URLs may be **added** in new app
  versions; existing ones must keep serving (or 404 — a 404 is just a failed candidate) forever.
- **Schema stays 1, changes are additive-only.** Clients ignore unknown fields and null out
  invalid optional ones. Never rename, retype, or repurpose an existing field; add a new one.

## Envelope format

```json
{
  "schema": 1,
  "payload_b64": "<standard base64 of the exact UTF-8 payload bytes>",
  "sig": "ed25519;<key_id>;<base64 signature>"
}
```

The signature covers the exact decoded `payload_b64` bytes (no JSON canonicalization anywhere).
`sig` is optional: an unsigned envelope decodes but is capped client-side at the passive Settings
row. A **present-but-invalid** signature fails that candidate entirely, so a tampered CDN copy
loses to a clean copy from the next candidate. `key_id` = first 8 bytes (hex) of SHA-256 over the
raw 32-byte public key — advisory routing only, all pinned keys are tried.

## Payload format

```json
{
  "schema": 1,
  "generated_at": "2026-07-22T12:00:00.000Z",
  "android": { "latest": "0.4.0", "latest_code": 12, "min_supported": "0.2.0" },
  "ios":     { "latest": "0.4.0", "min_supported": "0.2.0" },
  "promote": "silent",
  "notice": null
}
```

The manifest must never advertise a build that is not actually downloadable, so `latest` is
sourced per platform:

- **android.latest** — always the latest **release tag** (resolved at publish time), never a
  package.json version: a version bump whose release is still building or failed cannot be
  advertised before the APK exists. After a release completes, `release.yml` calls the publisher,
  which resolves the just-created tag. `latest_code` is present only when the tag matches the
  generating checkout's package.json version (otherwise unknowable and null; informational only,
  clients ignore it).
- **ios.latest** — always `ios_latest` from `release/update-policy.json`: iOS/TestFlight uploads
  are manual, so the operator records what is actually live and bumps it by policy PR after each
  TestFlight upload. CI rejects `ios_latest` above package.json and any `min_supported` above the
  advertised latest (a floor above what users can install would block them with no fix).

`min_supported`, `promote` and `notice` come from `release/update-policy.json`. `generated_at` is
the generating checkout's HEAD **committer time**, not wall clock — git history is the ordering
authority, so any late publish from a stale checkout carries an honestly-older stamp. It drives
rollback monotonicity: a client never replaces a cached *verified* manifest with an older
*verified* one, so neither a replayed signed manifest nor a stale-checkout publish can lower a
raised floor for clients that already saw the newer one. Unsigned envelopes can never displace a
verified cache at all.

## Client tier ladder (src/model/updateStatus.ts)

| Condition (per-platform section) | Verified required | UI |
| --- | --- | --- |
| up to date / no manifest | — | nothing |
| behind `latest` | no | passive "Update available" row in Settings |
| behind `latest`, `promote: "notify"` | yes | + one dismissible home banner per version |
| below `min_supported` | yes | full-screen "Update required" (with session-scoped "Continue anyway") |
| `notice` present, undismissed, unexpired | yes | dismissible home card (`level`: info/warn) |

Hard rules, in priority order:

1. **Fail open.** Network/storage/parse failures leave the app exactly as it was. The check never
   gates startup, rendering, or connect. All-candidates-fail = no update UI, retry in 15 min.
2. **Only a verified manifest can prompt or block.** Unsigned tops out at the passive row.
3. **Update destinations are pinned constants** (`AppConfig.UPDATE_URL_ANDROID`,
   `AppConfig.TESTFLIGHT_URL`) — never manifest-supplied, so even a signed manifest cannot
   redirect users to a hostile download. `notice.url` (https-only, verified manifests only) is the
   single server-supplied link, behind an explicit "Learn more".
4. **"Continue anyway" stays.** A custom-broker user on an "unsupported" build may still work;
   informing beats bricking (availability-first design).

## Serving the fronts (server-side TODO)

Until the two front routes exist, clients silently fall through to the GitHub asset — the system
works end-to-end from the first release. To light up the fronts, serve the R2 object
`openrung-downloads/app/update-manifest.json` at `/api/v1/app-manifest` on both:

- **Cloudflare Worker** (broker.openrung.org): bind the `openrung-downloads` bucket and return the
  object on that path with `content-type: application/json` and `cache-control: max-age=300`.
  Do not require any headers.
- **CloudFront** (d2r7mdpyevvs1m.cloudfront.net): add a behavior for `/api/v1/app-manifest` with a
  short TTL (300s), origin = the same R2 public endpoint (or proxy through the broker origin).

Integrity does not depend on these fronts (the payload is signed; a tampered copy just fails that
candidate), so caching/proxying is safe.

## Signing key

- Generate: `node scripts/update-manifest.mjs keygen` → prints `seed_b64` (SECRET), the public
  key + key_id to pin in `AppConfig.MANIFEST_SIGNING_KEYS`, and the vector message/signature pair
  to commit to `testdata/update_manifest_vectors.json` `pinned_keys` (the CI guard verifies the
  pin without the seed — same pattern as the relay signing keys).
- Store `seed_b64` as the GitHub Actions secret `OPENRUNG_MANIFEST_SIGNING_SEED_B64` **and** in
  the team password manager. It exists nowhere else.
- This is deliberately a **separate keypair** from the relay signing keys: the manifest key can
  hard-block app startup, so its power is scoped to exactly that.
- Rotation / loss: keygen a new pair, pin it (keys are a list — ship a release with both pinned),
  swap the secret, and after adoption remove the old pin. Losing the seed only degrades new
  manifests to unsigned (passive row) until a release ships a new pin — nothing bricks.
- The generate step refuses to sign with a seed whose public key is not in the committed
  `pinned_keys`, so a mis-set secret cannot silently produce manifests no client trusts.

## Runbooks

- **Routine release:** do nothing. `promote` stays `silent`; users see only the passive row.
- **After uploading an iOS build to TestFlight:** bump `ios_latest` in
  `release/update-policy.json` (PR to main) — until then the manifest keeps advertising the
  previous iOS version, by design.
- **Important release** (security fix, protocol change): set `promote: "notify"` in
  `release/update-policy.json` in the version-bump PR; set it back to `silent` in the next one.
- **Broadcast a notice / raise the floor:** edit `release/update-policy.json`, PR to main —
  `update-manifest.yml` republishes within minutes. Check broker `X-OpenRung-App-Version`
  telemetry before raising `min_supported` (how many users would you block?). CI rejects a floor
  above the current package.json version.
- **Kill a bad manifest fast:** revert the policy PR (or `workflow_dispatch` the publish workflow
  after fixing). Clients re-fetch within 6h, on next foreground, or on next cold start.
