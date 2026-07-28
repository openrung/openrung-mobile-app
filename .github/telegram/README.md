# Telegram release announcements

Copy for the four OpenRung Telegram channels (`@openrung_official`,
`@openrung_ru`, `@openrung_fa`, `@openrung_zh`), posted by
[`telegram-announce.yml`](../workflows/telegram-announce.yml) when a release is
published.

**In this repo, put the copy in `<tag>.md` here** — releases are published by
CI with `generate_release_notes: true`, so there is no hand-written release
body to hold it. Commit the file in the same version-bump PR that triggers the
release (`v` prefix included, matching the tag):

`.github/telegram/v0.3.5.md`

```
[en]
🔄 <b>OpenRung for Android — update 0.3.5</b>
• What changed, in terms a user can feel

[ru]
…
[fa]
…
[zh]
…
```

A `<!--telegram ... -->` block in the release body also works and takes
precedence — useful when announcing after the fact: add the block with
`gh release edit`, then run the workflow manually from the Actions tab
(untick *dry run*).

Text is sent with Telegram's HTML parse mode: `<b>`, `<i>`, `<code>` and
`<a href>` work; bare `&`, `<` and `>` must be escaped or Telegram rejects the
message and the job fails. Put `preview = on` above the first section to keep
link previews (useful when the preview itself is the point, like an Apple
TestFlight card).

No announcement for a release? Say so explicitly with an empty `<tag>.skip`
file here (or `<!--telegram:skip-->` in the release body) — otherwise the job
fails, which is what stops releases shipping unannounced.

Translations are written by hand, never machine-generated: these channels reach
people making risk decisions about censorship circumvention, and mangled Farsi
or an over-promising claim costs trust that is hard to win back. Write the
English, then ask for the RU/FA/ZH versions.

Because the app is sideloaded and does not auto-update, release posts usually
end with a reminder that installing the new APK over the old one is enough.
