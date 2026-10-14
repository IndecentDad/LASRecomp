# iPadOS port: what was measured (iPad Air 13" M2, iPadOS 26/27, Xcode 27, iOS 27 SDK)

Everything here was measured on the device or in the working build; the probe code lives in
`runtime/platform/ios.c` (`ios_probe_address_space`, runs when the guest window cannot be reserved) and the
commands are in `docs/ios.md`.

## The guest window

`runtime/rt.h` reserves one fixed 12.5 GB window at `0x7000000000` (upstream base). On iOS:

| attempt | result |
|---|---|
| `vm_allocate(FIXED)` at `0x400000000` (16 GB), 12.5 GB | **fails** |
| `vm_allocate(FIXED)` at 8, 10, 12, 16, 20, 24, 28, 32, 36, 40, 44 GB | **all fail** |
| `vm_allocate(FIXED)` at 16 GB, sizes 64 MB … 12.5 GB | **all fail** |
| `vm_allocate(ANYWHERE)`, 64 MB / 256 MB / 1 GB | OK, placed low (e.g. `0x10f134000`) |
| `vm_allocate(ANYWHERE)`, 2 / 3 / 4 / 6 / 8 / 12.5 GB | **OK, placed at `0x7000000000`** |

So the space below `0x7000000000` is not available to a fixed request (the app's own mappings, the dyld shared
cache region from `0x180000000` upward, and iOS's reservations occupy it), while above it the kernel is happy to put
large anonymous allocations — exactly where the upstream layout wants the guest. Consequence: **the iOS build keeps
the upstream base and shares `generated/`**; no second guest layout exists.

Two other APIs matter: `<mach/mach_vm.h>` is an `#error` stub on iOS (`#include <mach/vm_map.h>` and `vm_allocate` /
`vm_region_64` are the supported ones — `mach_vm_*` symbols *are* exported by libSystem, but undocumented), and
Darwin has no `MAP_FIXED_NOREPLACE`, so `mmap(MAP_FIXED)` would silently clobber an existing mapping: `vm_allocate`
(which fails instead) is used.

## Entitlements

* `com.apple.developer.kernel.extended-virtual-addressing` — required: the window sits above the default per-app
  address space (`MACH_VM_MAX_ADDRESS_RAW 0xFC0000000`, 67.6 GB; xnu `osfmk/mach/arm/vm_param.h`). The Apple
  Development profile for the paid team provisions it automatically; the app builds, signs (entitlement visible in
  `codesign -d --entitlements -`) and launches with it.
* `com.apple.developer.kernel.increased-memory-limit` — for the guest heap's jetsam budget.

## The window is its own problem (iPadOS 26 windowed apps)

SDL's UIKit backend predates iPadOS 26's windowed apps: it computes the SDL view's frame from `UIScreen.bounds`,
which is **always the portrait size** (1024x1366 pt on the iPad Air 13"). In a landscape window the view therefore
comes out as a portrait rectangle parked at the window's origin, and the game (16:9, letterboxed inside that
rectangle) shows up as a box in the corner of the screen - with `SDL_GetWindowSizeInPixels` also reporting the
screen instead of the window. Measured on the device: scene bounds 1366x1024 pt (landscape) while the SDL view was
1024x1366 pt and the drawable 2048x2732 px.

Fixed in `runtime/nvn/metal.m` (`ui_drawable_size`, used by both the start screen and the game loop):

* the SDL view is fitted to the window it is in (`view.frame = window.bounds`, re-applied if SDL moves it), so the
  drawable becomes the window's real size (2732x2048 px = 1366x1024 pt here), and
* the drawable size comes from that view, not from SDL's report.

`runtime/platform/ios_ui.m` additionally asks the window scene for landscape and constrains the window with
`UISceneSizeRestrictions` (minimum: a landscape 16:9 rectangle; maximum: the screen's landscape bounds), which is
the iPadOS 26 API for exactly this - a game that must not be a tall portrait window.

Result on the device: the start screen and the game fill the screen in landscape, and the 16:9 movies are
full-width and centred (with the ~12% letterbox a 16:9 film has on the iPad's 4:3 screen).

## Memory

* The host's own run at 2560x1440 logged `mem 1421 MB` (guest + GPU + textures) at 60 fps with the opening movie
  decoding — that is the scale the iPad has to accommodate; `os_proc_available_memory()` is logged at startup
  (`[ios] available memory before boot: … MB`) and the increased-memory-limit entitlement raises the ceiling.
* `MTLDevice.maxBufferLength` matters because the whole 3.25 GB guest heap is wrapped in one `MTLBuffer`
  (`runtime/nvn/metal.m`): the log line `heap buffer … MB (device maxBufferLength … MB, working set … MB)` reports
  it on every run. The macOS build creates the wrap at the same `HEAP_MAX`, so the value on the M2 is expected to
  match; if the iOS one is smaller, the wrap fails with that message (the fix would be windowed heap buffers).

## Things that are impossible on iOS (and how the port avoids them)

| desktop feature | iOS |
|---|---|
| building the game code with `lasgen` + `zig cc` on the player's machine | cross-compiled on the Mac, linked in (`build/ios/liblasgame_ios.a`); `runtime/gamebuild.c` is not compiled in, `plat_spawn()` returns 0 |
| `dlopen`ing the freshly built `lasgame.dylib` | `LARECOMP_STATIC_GAMELIB` calls `lasgame_tables()` directly |
| re-exec on a guest-window collision | `plat_exec()` reports and exits |
| `/usr/bin/curl` update check | not compiled in |
| randomizer seed generator (a Python helper) | seeds are generated on a Mac and copied into `rando/<seed>/` |
| `SDL_ShowOpenFolderDialog` | SDL has no UIKit dialog backend: the files are copied into the app's Documents (Files app / Finder / `make ios-files`) and the setup page offers Rescan |
| `NSProcessInfo` App Nap exemption | macOS-only API; guarded out (iOS suspends instead, which is handled by SDL's lifecycle events) |
| `MTLPixelFormatDepth24Unorm_Stencil8` | macOS-only; guarded out in `runtime/nvn/renderer.m` |

No JIT or executable memory is involved anywhere (`PLAT_PROT_*` has no EXEC), so no JIT entitlement is needed.
