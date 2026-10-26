# Golden cases for saving the config

Run by **both** apps (`golden_test.go`, and `swift/TVCore/Tests/.../GoldenTests.swift`)
so that what one saves the other reads the same. YAML text differs between the two
emitters, so cases compare *meaning*, not bytes.

Each directory is a case:

| File | |
| --- | --- |
| `before.yaml` | the config as loaded. Required. |
| `wireguard.txt` | optional: file names to create in `wireguard/` next to it. `../x.conf` goes in the config dir instead. |
| `edit.json` | optional: what the settings panel sends as `config` (window, media, user_agent, channels). Absent: save the config as loaded. |
| `expected.json` | `{config, tunnels, warnings}` after save and reload. `tunnels` is `vpn.tunnels` as written in the file (null with no vpn block); warnings are sorted, with the home directory shown as `$HOME`. |

The config lives at `$HOME/cfg/channels.yaml` with `HOME` a scratch directory, so
paths come out as `~/cfg/...`.

Regenerate `expected.json` with `go test -run Golden -update-golden`, **then read
the diff**: it is the specification.
