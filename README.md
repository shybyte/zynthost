# Zynthost

Host for LV2 Synth-Plugins written in Zig

## Build

Requires Zig 0.17.0 and development libraries for Lilv, LV2, PortAudio,
PortMidi, Suil, and GTK 2 (with pkg-config).

```bash
zig build
zig build test
zig build run -- patches/demo/patch-set.json
```

The integration tests require MIDI devices and the Surge XT LV2 plugin.

## Hints

- Using I3, preset selection works only in floating mode (for_window [ title="Surge XT" ] floating enable)

### Alternatives

```bash
jalv.gtk3  https://surge-synthesizer.github.io/lv2/surge-xt
```
