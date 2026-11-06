# Zynthost

Host for LV2 Synth-Plugins written in Zig

## Build

Requires Zig 0.17.0 and development libraries for Lilv, LV2, PortAudio,
PortMidi, Suil, and GTK 3 (with pkg-config).

```bash
zig build
zig build test
zig build run -- patches/demo/patch-set.json
```

The integration tests require MIDI devices and the Surge XT LV2 plugin. Nori
integration tests run when its LV2 bundle is discoverable and skip otherwise.

## Closing plugin windows

Set `"exit_on_last_ui_closed": true` in the patch-set JSON to exit the host when
the last opened plugin UI closes. It defaults to `false`. Headless patches
(including `"show_ui": false`) keep running. Closing a window does not save state;
use `s` in the terminal before closing it to save the active phrase.

## Nori

Build Nori in its own repository and make its `nori.lv2` bundle discoverable
through `LV2_PATH` or an LV2 installation directory such as `~/.lv2`.
Check discovery with `lv2info urn:nori:singing-voice`, then use the VS Code
**Run Nori** task or:

```bash
zig build run -- patches/demo/nori-patch-set.json
```

The host supports Nori's background pronunciation worker, mono output routed to
both stereo channels, and Atom messages between its GTK 3 editor and audio
processor. Lyrics, phoneme edits, reset requests, and status notifications travel
through queues between the UI and audio threads. Atom buffers honor the plugin's
minimum buffer sizes. The first run uses Nori's default phrase; press `s` in the
terminal to save the current phrase and `q` to quit.
The Nori demo enables `exit_on_last_ui_closed`, so closing its editor also quits
the host.

## Hints

- Using I3, preset selection works only in floating mode (for_window [ title="Surge XT" ] floating enable)

### Alternatives

```bash
jalv.gtk3  https://surge-synthesizer.github.io/lv2/surge-xt
```
