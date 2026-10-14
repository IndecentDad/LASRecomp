# LAS Recomp on iPadOS

A locally built iPadOS app: the same runtime and start screen as the desktop builds, with the recompiled v1.0.0
game code linked in and the game files kept in the app's Documents folder. **Personal use only** - the signed app
contains code derived from your own copy of the game, so don't share the `.app`/`.ipa`.

## What is different from the macOS build

| | macOS | iPadOS |
|---|---|---|
| Guest window base | `0x7000000000` (481 GB) | **the same** (`0x7000000000`); needs the Extended Virtual Addressing entitlement |
| Game code | built on the machine (`lasgen` + `zig cc`), `dlopen`ed | **linked in**: `make ios-game-lib` → `build/ios/liblasgame_ios.a` (same `generated/`, same base) |
| SDL3 / FFmpeg | Homebrew or `build/deps`, dylibs in the .app | **static** (`tools/build_deps_ios.sh` → `build/ios/deps`) |
| Game files | `<data root>/extracted/` (exefs + romfs + romfs.bin) | the app's **Documents** folder (`exefs/`, `romfs.bin` and `romfs/region_common/movie/`) |
| Randomizer seeds | generated in-app (Python helper) | generated on a Mac, copied into `rando/<seed>/` |
| Update check | `/usr/bin/curl` | none (no second process on iOS) |
| Input | keyboard / mouse / controller | controller (Bluetooth or MFi); the overlay menu is touch-tappable |

Why the entitlement: the guest window is one fixed 12.5 GB reservation at `0x7000000000`, which is above the default
address space an iOS app gets (`MACH_VM_MAX_ADDRESS_RAW 0xFC0000000`, 67.6 GB — xnu
`osfmk/mach/arm/vm_param.h`). `com.apple.developer.kernel.extended-virtual-addressing`
(`ios/LASRecomp.entitlements`) is what raises it; an Apple Development profile provisions it automatically (verified:
the app builds, signs and launches with it). Without it the reservation fails and
`runtime/platform/ios.c` prints the task's address space and exits instead of misbehaving. Measured on the iPad Air
(M2): `vm_allocate(ANYWHERE)` for 2–12.5 GB lands exactly at `0x7000000000`, the upstream base, so the iOS build
shares the desktop's `generated/` game code — there is no second base to keep in sync.

`com.apple.developer.kernel.increased-memory-limit` is also set: it asks for the larger jetsam budget the guest
heap (up to 3.25 GB, backed only as the game touches it) wants.

## One-time setup

```sh
brew install python@3.12 xcodegen                      # the generator venv + the Xcode project
/opt/homebrew/bin/python3.12 -m venv tools/venv
tools/venv/bin/pip install capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5 numpy pillow
make -j10 && make gen && make -j10                     # the desktop build first (it validates your game files)
tools/check_game_files.sh extracted                    # v1.0.0 build id, exefs, romfs
./build/lasrecomp --build-romfs extracted/romfs extracted/romfs.bin
tools/build_deps_ios.sh                                # static SDL3 + FFmpeg for iOS (a few minutes)
```

Your own extracted game files are needed: `exefs/` (main, main.npdm, sdk) and `romfs/` from **v1.0.0**
(the recompiler, the randomizer patches and every hardcoded game address are for that revision; the base game NSP
`01006BB00C6F0000` v0 is it). `tools/check_game_files.sh` verifies the build id.

## Build, install, run

```sh
make ios-gen            # game code for the iOS base -> generated-ios/ (a few minutes)
make ios-game-lib       # -> build/ios/liblasgame_ios.a (the long one: ~720 generated files)
make ios-app            # xcodegen + xcodebuild -> build/ios/dd/Build/Products/Debug-iphoneos/LAS Recomp.app
make ios-install        # xcrun devicectl device install app (IOS_UDID=<your iPad>)
make ios-files          # push extracted/exefs + extracted/romfs.bin into the app's Documents folder
make ios-run            # launch with the console attached (stderr = the runtime log)
```

`IOS_UDID` defaults to the iPad Air 13" (M2) this was developed against, `IOS_TEAM` to the Apple Development team
in `tools/ios.mk`; override both on the command line. `DEVELOPER_DIR` is set by the build, so a `xcode-select` that
points at the Command Line Tools is fine. Opening `build/ios/LASRecomp.xcodeproj` in Xcode works too: pick the
scheme `LASRecomp`, your team, and Run.

Game files, the other way: with `UIFileSharingEnabled` the app's Documents folder is visible as "On My iPad > LAS
Recomp" in the Files app and under Finder > your iPad > Files > LAS Recomp. Put `exefs/`, `romfs.bin` and
`romfs/region_common/movie/` there (exactly where `make ios-files` puts them) and press **Rescan** on the start
screen's setup page. The 5.8 GB `romfs/` tree the image is built from is *not* needed on the device: the game reads
everything through `romfs.bin` - except the three videos (`opening.webm`, `title.webm`, `ending.webm`), which its
FFmpeg-based decoder opens by path, so they stay loose files. Without them the forced first-run opening movie is a
black screen.

**Install first, then copy the game files**: reinstalling the app recreates its data container, and anything in
Documents goes with it.

## What is not there (yet)

- **Touch controls.** The game expects a controller. A virtual gamepad is the planned next step: SDL's virtual
  joystick (`SDL_AttachVirtualJoystick`) feeding the existing binding table, so remapping and button prompts keep
  working unchanged. Today the on-screen UI is touch-tappable (SDL turns touches into pointer events for ImGui).
- **In-app seed generation.** The generator is a Python program run as a second process, which iOS forbids. Generate
  a seed on a Mac (the desktop start screen, or `make rando-helper`) and copy its `rando/<seed>/` folder into the
  app's Documents folder; it then plays like any seed, and switching seeds reboots the game in place.
- **The in-app update check** (desktop-only, it shells out to curl).

## Notes for working on the port

- `runtime/platform/ios.c` is the host layer (mach time, guest window, crash handler). `plat_spawn()` returns 0 and
  `runtime/gamebuild.c` is not part of the iOS target, so nothing can silently depend on starting a process.
- `ios/project.yml` is the single source of truth for the app target (sources, frameworks, `RT_BASE`); `make
  ios-xcode` regenerates the Xcode project from it. The runtime sources stay in `runtime/`, so both builds share
  them; only the platform layer and the guest base differ.
- The guest window is reserved by a `constructor(101)` before `main` (`runtime/main.c`). On iOS a collision cannot be
  recovered by re-executing (`plat_exec` fails with a message) - if that ever happens, the base in
  `tools/ios.mk` (`IOS_BASE_MAIN`/`IOS_BASE_SDK`) and `ios/project.yml` (`RT_BASE`) has to move, and the game code
  regenerated for it.
- `make ios-run` prints the runtime log live; without a cable, the app writes no log file yet (a to-do).
