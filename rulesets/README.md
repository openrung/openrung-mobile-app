# Bundled split-tunneling rule sets

`rulesets/dist/` holds the four compiled sing-box rule-set binaries (`.srs`)
behind the split-tunneling country presets (`ir`, `cn`). They ship inside both
apps: the Android build copies them into APK assets (`rulesets/<name>.srs`,
staged at runtime to `<filesDir>/libbox/rulesets/`) and iOS bundles them as
explicit PacketTunnel resources. At runtime a country preset is applied only
when both of its files are present and readable; a missing or unreadable file
drops that preset with a log line and never breaks connect
([`docs/CONTRACT.md`](../docs/CONTRACT.md) §1, fail-open).

Do not edit the binaries in place. A refresh replaces the files, updates the
provenance table below, and re-validates every file.

## Provenance

| File | Source repository | Branch @ commit | Fetched | SHA-256 | License |
| --- | --- | --- | --- | --- | --- |
| `geosite-ir.srs` | [Chocolate4U/Iran-sing-box-rules](https://github.com/Chocolate4U/Iran-sing-box-rules) | `rule-set` @ `ef8d0d7afead` | 2026-07-22 | `22add255a0ea2fccc799a0c45508df5b67319d9d2c30ed2ad37bfa4e6d67ce81` | GPL-3.0 |
| `geoip-ir.srs` | [Chocolate4U/Iran-sing-box-rules](https://github.com/Chocolate4U/Iran-sing-box-rules) | `rule-set` @ `ef8d0d7afead` | 2026-07-22 | `36d46ea40dfe65d722ee4a4171bc93db8ad6f5dd75265ffb448979761ece9c53` | GPL-3.0 |
| `geosite-cn.srs` | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) | `rule-set` @ `63c859070624` | 2026-07-22 | `a0dba9663dd160836106740198ed2ce78aa348946e50e5f5666e9a8b7c4097e4` | MIT (data from [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)) |
| `geoip-cn.srs` | [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip) | `rule-set` @ `5605651c12ed` | 2026-07-12 | `bc1a9eb66f9c6a0fe9fc5300cf5b5e885e0f9eadd7213b085b767a95d6af3d2a` | MaxMind GeoLite2 data (attribution required) |

Attribution obligations (GPL-3.0 for the Iran rule sets, the MIT
domain-list-community notice, and MaxMind's "This product includes GeoLite2
data created by MaxMind, available from https://www.maxmind.com") are carried
in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Refreshing

Fetch the current files from each upstream's `rule-set` branch:

```sh
cd rulesets/dist
curl -fLO https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs
curl -fLO https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs
curl -fLO https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
curl -fLO https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
```

Then update the provenance table: record each repository's `rule-set` branch
head commit at fetch time, the fetch date, and the new hashes from

```sh
shasum -a 256 rulesets/dist/*.srs
```

## Validation

Every file must decompile with the **pinned** sing-box CLI before it is
committed (run from the repository root; `SINGBOX_VERSION` holds the pinned
revision — the same one the shipped libbox is built from):

```sh
go run github.com/sagernet/sing-box/cmd/sing-box@$(cat SINGBOX_VERSION) rule-set decompile <file> -o <out.json>
```

A file the pinned CLI cannot decompile must not be committed: the engine that
loads it at runtime is built from that exact revision.
