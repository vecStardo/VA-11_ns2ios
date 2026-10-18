# VA-11 HALL-A — Nintendo Switch → iOS port

Run **your own** Nintendo Switch copy of *VA-11 HALL-A: Cyberpunk Bartender Action* natively on
iPhone and iPad. This repository contains an iOS compatibility layer for the GameMaker/Switch build
of the game, plus an unsigned `.ipa` packaging pipeline.

**Version:** `v1.0.0` (first official release — initial port) ·
[Release](https://github.com/vecStardo/VA-11_ns2ios/releases/tag/v1.0.0) ·
[Changelog](CHANGELOG.md) · 中文文档: [README.zh-CN.md](README.zh-CN.md)

> **This repository contains no game content and no keys.**
> `game.win` (~520 MB) is the complete game data package (GML bytecode, textures, audio, text) and
> must be provided by you from the original game you own. See [Compliance](#compliance--legal).

---

## Features

- **Native iOS execution** of the Switch build: the game modules (`main`, `sdk`, `subsdk0`,
  `subsdk1`) are re-linked and executed on Apple silicon; no emulation layer is involved.
- **HLE host layer** for the Horizon services the game uses: file system, input, audio, time,
  account, error dialogs — adapted from the d2r-mobile project.
- **Graphics**: the game's EGL/GLES calls are served directly by EAGL on iOS.
- **Dialogue system**: the Switch release stores dialogue in romfs (`scripts/<lang>/*.ini`);
  the app bundles `eng` / `chn` / `jp`, extracts them on first launch, and loads them synchronously
  through a patched `game.win` (fixes the "day 0 black screen").
- **Two default languages**: `game_patched_EN.win` / `game_patched_CN.win`
  (the Switch build auto-selects the language and skips the LANGUAGE SELECT screen).
- **Audio**: `AVAudioSession` playback at 48 kHz and a fix for the game's partially filled audio
  buffers (which otherwise caused half-rate, crackling audio).
- **Save/load** with transactional writes (atomic swap of the save directory).

## Status

This is a **first official release, and an incomplete one**: it boots and is playable up to the bar
scene, but the full game loop has not been verified end to end.

| Area | State |
|---|---|
| Unsigned IPA install (iOS 16+, bundle `local.va11.mobile`) | ✅ |
| Title → language select → new game → bar scene | ✅ |
| Multiple dialogue advances (English / Chinese) | ✅ |
| Save / load | ✅ basic read/write verified |
| Audio (music / effects) | ✅ fixed and verified |
| Full playthrough (bartending, all chapters, endings, all settings) | ❌ **not verified** |

Verified on the iOS Simulator and on a real device through LiveContainer.

## Requirements

- **Users**: an iPhone/iPad on iOS 16+, a sideloading tool (Sideloadly, LiveContainer, …), and your
  own Switch copy of the game (`game.win` + the romfs `scripts/` folder).
- **Building**: macOS with Xcode (16+ recommended), `xcodegen`, Python 3; the reference rewriter
  works on the game modules you provide.

## Quick start (users)

1. Install `Va11IOS-<version>-unsigned.ipa` with your sideloading tool.
2. Apply the dialogue patch to your own `game.win` and place the result at `Documents/save/game.win`:
   ```sh
   tools/romfs_patch/apply_patch.sh <your game.win> game_patched_EN.win      # English default
   tools/romfs_patch/apply_patch.sh <your game.win> game_patched_CN.win cn   # Chinese default
   ```
3. Copy the romfs dialogue folder (`eng/` or `chn/`) into `Documents/save/` if your IPA was built
   without bundled texts (the release asset is a clean build).
4. Launch the app → LANGUAGE SELECT → New Game.

Diagnostics are written to `Documents/boot.txt`; attach it when reporting issues.

## Build from source (developers)

```sh
# 1) rewrite the four game modules for Apple silicon (outputs to ~/va11-work/patched)
DM_FOREIGN_GAME=1 DM_RULESET=native python3 va11mobile/dm/tools/patch_nso.py <exefs/main> <out> main
#    … repeat for sdk, subsdk0, subsdk1

# 2) package the unsigned IPA
cd va11mobile/iosapp
DM_PATCHED=~/va11-work/patched ./build.sh                 # bundles eng/chn/jp dialogue texts
DM_TEXTS_ROMFS=/nonexistent DM_PATCHED=~/va11-work/patched ./build.sh   # clean build, no game text
```

The build script embeds the rewritten images, runs `xcodebuild` (unsigned, arm64), assembles the
`Payload`, writes `out/Va11IOS-<version>-unsigned.ipa`, and verifies the result (segments, bundle,
version, ad-hoc signing rehearsal) — it must report **0 red items**.

## Repository layout

```
README.md / README.zh-CN.md     project documentation (this file / Chinese)
CHANGELOG.md                    release notes
RELEASE.zh-CN.md                distribution boundaries (what must never be published)
va11mobile/
  VERSION                       version source of truth
  dm/host/                      HLE host (shared by the macOS host and the iOS app)
  dm/gfx/                       NVN → Metal layer (not used by VA-11)
  dm/tools/patch_nso.py         program rewriter
  iosapp/                       iOS app + unsigned packaging pipeline
  docs/LESSONS.zh-CN.md         methodology and pitfalls
  docs/PORTING.zh-CN.md         porting internals
  skills/va11mobile/SKILL.md    end-to-end build/install/verify playbook for agents
  verify/                       investigation log and verification records
tools/                          data tools (GML decoder, romfs patch, save helpers)
```

## How it works

1. **Rewriter** (`va11mobile/dm/tools/patch_nso.py`): replaces instructions that cannot run under
   the Apple kernel (`svc`, `mrs cntpct`, `x18`/TLS usage, system counters) with calls into host gates.
2. **Host loader + HLE** (`va11mobile/dm/host/`): maps the rewritten images back, performs
   cross-module relocations, and implements the SDK services the game calls.
3. **Graphics**: EGL is mapped onto EAGL; the game renders into an `CAEAGLLayer` at its native
   resolution and is scaled to the screen.
4. **iOS shell** (`va11mobile/iosapp/`): window, EAGL view, touch injection, logging, lifecycle,
   audio session, and the unsigned packaging pipeline.

## Game data and language

- `game.win` is the complete game data package; it is **never** shipped here.
- Dialogue is **not** in `game.win`: it lives in romfs as `scripts/<lang>/*.ini`
  (`eng`, `chn`, `jp`, …). The app bundles three languages and extracts them to
  `Documents/save/<lang>/` on first launch.
- The Switch build picks a language from the system setting and skips the LANGUAGE SELECT screen,
  so two patched data variants are provided to select the default language.
- The third-party "1.0.1 Chinese patch" does not match the 1.0.0 base data used here and is not
  used; Chinese text comes from the game's own romfs `chn` files.

## Verification

- `Documents/boot.txt` reports boot state, dialogue file loads, audio statistics and render FPS.
- `audio 统计` should show ~57 appended buffers/s, no zero-filled gaps, and zero underruns.
- `渲染统计` shows ~27 FPS on the simulator and ~30 FPS on device (the game itself is locked to
  30 FPS; 60 FPS is neither expected nor required).

## Known limitations

- Full playthrough has not been verified (bartending minigame, all chapters/endings, every setting,
  long-session stability).
- Requires your own copy of the game, plus a one-time patching step for `game.win`.
- The third-party Chinese patch for 1.0.1 is incompatible with the 1.0.0 data used here.
- No App Store distribution; unsigned IPA only (sideloading required).

## Compliance & legal

- No game files, no NSP/NSZ/XCI, no `prod.keys`/`title.keys`, no romfs dialogue text in this
  repository (audited across the full git history).
- The release asset is a **clean build** without game text.
- Patched `game.win` files, IPAs with bundled dialogue and extracted dialogue folders are for your
  own device only — do not publish them. See [RELEASE.zh-CN.md](RELEASE.zh-CN.md).
- You must own the game to use this project.

## Credits & acknowledgements

- **d2r-mobile** (<https://github.com/d2r-mobile/d2r-mobile>) — the direct ancestor of this port:
  the rewriter, the HLE host architecture, the EAGL path and the audio pipeline all originate there.
  Without that project this port would not exist. Portions of `va11mobile/dm/` are derived from
  d2r-mobile (MIT, © 2026 jhaizhou).
- **UndertaleModTool** — used to decompile `game.win` and identify the dialogue loading logic.
- The GameMaker and Horizon homebrew communities for documentation of the runtime and service APIs.
- VA-11 HALL-A is © Sukeban Games / Ysbryd Games. This project is unaffiliated fan work.

## License

MIT. See [LICENSE](LICENSE).
