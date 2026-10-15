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

## The on-screen pad's virtual gamepad indices (a trap worth remembering)

`SDL_SetJoystickVirtualButton()` / `…VirtualAxis()` take a **joystick** index, while the joystick's index space is
built from `SDL_VirtualJoystickDesc.button_mask` / `axis_mask` by counting the set bits up in `SDL_GAMEPAD_BUTTON_*`
/ `SDL_GAMEPAD_AXIS_*` order (`SDL_virtualjoystick.c`, the mapping generator). A sparse mask therefore *shifts* every
index after the first gap, and a wrong index is not an error: `SDL_SetJoystickVirtualButton()` only rejects indices
past `nbuttons`, so the press lands on a button the generated mapping does not cover and silently does nothing
downstream.

That is what made the pad's L / R / ZL / ZR (and `+`) dead while A / B / X / Y worked: the mask listed eight buttons,
so L (gamepad 9) and R (gamepad 10) wrote joystick buttons 9 and 10, and the triggers wrote axes 4 and 5 of a
four-axis mapping. `runtime/ui/touch_pad.mm` now sets *every* button and axis bit, which makes the joystick's index
space the `SDL_GAMEPAD_*` enumeration the rest of the file already speaks.

To check a pad mapping without a finger on the glass, `LARECOMP_TOUCH_TEST="<frame>:<ctl>[&<ctl>]…"` (with
`LARECOMP_TOUCH_HOLD`) feeds the pad the events a real touch produces, and a temporary `LOG` in
`runtime/hle/input.c`'s `SDL_EVENT_GAMEPAD_BUTTON_*` / `…_AXIS_MOTION` case prints which button / axis index the
input layer actually saw.

## The over-bright glow on iPad (open: one draw's shading parts ways on the M2)

Symptom: in bright doorways Link's tunic and hands blow out to white and the window lights streak; it is
iPad-only (macOS renders the same frame correctly). The iPad here is Apple M2, the Mac an M3 Pro: two
GPU generations of the same family, and the shader with the blow-out is Link's body fragment shader
(fingerprint `6804ba6e5340c6f9`).

The investigation moved from "the frame looks different" to "this one draw's output differs" with the
runtime's debug frame (`LARECOMP_DEBUG_FRAME=<n>` dumps every render pass to `build/pass_NNN.png`, every
fragment texture bound to `build/dtex_NNN_i.png`, plus the draw log). Dumping the same frame on both
platforms lines the pass numbering up exactly, and the difference is local: Link's tunic and hands are
pure white (255,255,255) where macOS is dark (mean 4,13,3), the lit objects and the floor's window light
are somewhat darker, and the rest of the frame is identical to the last bit. Bloom then spreads the
blown-out pixels (`5bcc5bba74542b30` and friends), which is the "glow" that was measured first.

Everything the draw receives was then compared per platform, at the same frame, same warp and same
inputs (`tools/cmp_passes.py`, `tools/cmp_draw_inputs.py`):

| checked | result |
|---|---|
| pass sequence and sizes (27 passes) | identical, pass by pass |
| draw order, shader fingerprints, counts, render target, viewport, attributes, vertex streams | identical |
| generated **MSL** of Link's fragment shader | byte-identical (dumped from the device, diffed) |
| fragment uniform buffers (f0..f17) | byte-identical except 6 floats in f1 that the shader never reads |
| the draw's textures (1024x1024 BC1 albedo, two 512x512 BC4 masks) | byte-identical |
| vertex uniform buffers | differ only in the camera matrix (~0.15 deg) and one scalar |
| vertex storage buffer | identical contents; only the guest's declared range size differed between runs |

So the state is the same to within a fraction of an animation frame (the camera is still interpolating
when the room loads), and the code, the uniforms and the texels are the same - the two GPUs simply
evaluate that shader differently. The candidates that were tested and are *not* the mechanism:

- **the per-draw highlight tint** (golden pots): `LARECOMP_LOG_TINT` keeps a log of every nonzero tint and
  it never fires on either platform without a randomizer seed (`[tint]` lines: none).
- **BC1 textures**: decoding them on the CPU changed the readback, so that path is not what the GPU
  samples; with it reverted the device's albedo is byte-identical to the Mac's and the tunic still blows.
- **the shadow comparison**: `LARECOMP_NO_SHADOW` (comparison always passes) does not move it.
- **Metal's fast math**: compiling the shaders with `fastMathEnabled = NO` does not move it.
- **out-of-domain transcendentals**: keeping `log2` / `sqrt` / `rsqrt` arguments in domain (see below)
  does not move it either.
- point vs bilinear sampling of the RG11B10 bloom levels (measured earlier, see above).

Two further measurements settle the arithmetic candidates:

- **The texture fetch is correct.** `LARECOMP_DBG_FS=72fbab9300:208:8` (the albedo sample) renders
  Link's silhouette as that register: max 147, no white pixels. So BC1 / sRGB / mip / sampler are all
  exonerated and the blow-up is in the lighting.
- **Neither the approximate transcendental units nor their precision are it.**
  `LARECOMP_PRECISE_MATH` routes every MUFU through Metal's `precise::` (IEEE) versions; in the *scene
  target* the device goes from 16969 to 17687 white pixels (Link's crop 14073 -> 14791) against the
  Mac's 3651 / 0.

**Judge a candidate on the scene target, not the window shot.** `pass_006` is the scene before the
bloom, `LARECOMP_WINDOW_SHOT` includes it. `LARECOMP_LOD_MAX=0` (8160 -> 3853),
`LARECOMP_NO_DEPTH_SCALE` (8160 -> 4430) and `LARECOMP_PRECISE_MATH` (8160 -> 3323) each look like a
partial fix in the window shot, but they only shrink the bloom *halo* around Link - his core stays pure
white in the scene target every time, where the Mac is 3651 and the device 16969.

Also: `LARECOMP_DBG_FS` hangs the macOS build (the render loop stalls at frame 11 with a 54-second
frame) while the same probe runs fine on the iPad, so cross-platform register comparison is
device-only until that is understood.

What is in the tree from this: the MUFU ops clamp their argument and `LARECOMP_PRECISE_MATH` selects
the IEEE variants, and the runtime tint clamps its luminance/exponent, so a NaN cannot reach the HDR
target and be read as a saturated white pixel. That is defensive rather than a fix for this case.

Next: **mip levels.** Link is white in every one of 16 consecutive frames from the moment the room
appears (frames 9400-12200, `build/dev_frames/`), while the camera is still moving, so it is not a
threshold and not a state artifact - the same draw is simply shaded differently. The one input the
comparison above did *not* cover is the texture's mip levels: `renderer_save_texture` samples through
`present_sampler`, which is created with `MTLSamplerMipFilterNotMipmapped`, so every `dtex_*.png` ever
diffed was mip **level 0** only. Link is a small object on screen, so his shader's implicit derivatives
select a deeper mip, while the room's large BC1 surfaces sit at level 0 - which is exactly the split
seen in the frame (only Link wrong; the room's BC1 objects fine). A mip that `upload_texture` never
filled in is uninitialized, and uninitialized contents are not the same across GPU generations.

So the next step is to view level N of a texture: add `LARECOMP_DUMP_MIP=<n>` to `renderer_save_texture`
(a `newTextureViewWithPixelFormat:...levels:NSMakeRange(n, 1)` view), dump Link's 1024x1024 BC1 albedo
(`dtex_067_4`, guest format `0x46`) at levels 0-4 on both platforms and compare. If the deeper levels
differ (or read back blank), the fix is in `upload_texture`'s per-level blit or in the texture's
`mipmapLevelCount`, not in the shader.

Bisecting the shading itself needs `LARECOMP_DBG_FS=<fs addr>:<pc>:<reg>`, which pushes one register of
a chosen instruction out as the pixel value; fragment code addresses are stable across runs and
platforms (e.g. `72fbab9300` for Link's body shader). `pc 1f0`-`238` are the four `sample_compare`
shadow taps, `pc 208`/`248`/`250` are the albedo and mask fetches, `pc 22f0` is the final colour.



## Register bisection (working method)

`LARECOMP_DBG_FS_HASH=<fingerprint>:<pc hex>:<reg>` makes exactly one shader (by the same
fingerprint the `[fshash]` log prints) output that register as the pixel value after the
instruction at `pc`, so the scene-target dump shows the register across the object's silhouette
(all three channels equal). Both platforms must run the same probe *and* the same pacing
(`LARECOMP_LAUNCHER_AUTOPLAY`, the same `LARECOMP_INPUT`, no extra per-frame logging), then
compare the histogram of equal-channel pixels: the two runs' pixel counts come out close enough
(50k vs 52k below) that the distributions are comparable across runs.

First result, and the reason this is now a real bisection: **`pc 9d8 reg 7` (`r7 = 1/r7`, the
first reciprocal, right after `pc 9c8: r7 = fmax(r7, cb1[1][0])`) matches** - Mac 50180
equal-channel pixels in bands 3-20/20-80/80-200/>200 = 617/712/3650/10077, iPad 51943 =
706/585/3436/9621. So that reciprocal is not where they part ways; the walk continues.

Remaining register sites, in execution order, with what they hold (from the annotated MSL):
`pc 648 r4` the four-tap shadow sum; `pc 918 r4/r5` banked light reads; `pc 9d8 r7` 1/x (matches);
`pc aa8/ab0 r4/r5` light x albedo; `pc c68 r4`, `pc c90 r5`, `pc f10 r6`, `pc 1148 r6`
(fma(r36,r36,...) then 1/x) further reciprocals; `pc cc8/cd8/1268/1368` saturate() light factors;
`pc 2018 r0` log2; `pc 2130 r2` exp2; `pc 2250/22d0 r0` accumulation; `pc 2310 r0` pre-clamp.

The probe has a blind spot worth remembering: the dump goes through an RGBA8 target, so a probed value
>= 1.0 clips to 255 and two platforms that both saturate look identical. Probe the *input* of a suspect
operation (a small value that can cross zero) rather than its output. Also, the object is found by the
densest 64x64 tile of equal-channel pixels (a whole-image histogram is dominated by grey scene pixels
and the black border), and each probe dump must be pulled to a unique name right away - the device
overwrites Documents/build/pass_006.png on every run. `tools/cmp_probe.py` does the above.

## The probe is a path indicator, and that reframes the bug

`pc 1148` and `pc bd0` probes came back with *no* silhouette at Link's position on the device
(densest lit tile elsewhere, a few hundred pixels), while `pc 208` (texture sample) and `pc 9d8`
(first reciprocal) both landed exactly on him. The reason: the translated shader is a
`switch (pc)` state machine with branches, and the probe writes the register at one pc of *all*
paths - pixels that never execute it keep the initial `dbgv = -1.0f`, which clamps to 0 in the
dump and is invisible against the scene's dark areas. So:

- only pcs on the *unconditional* path probe usefully;
- a pc that is written on one branch and not another is a **path indicator**: untaken shows black.

That matters because the leading explanation for "identical MSL, identical uniforms, identical
texels, completely different picture" is no longer arithmetic - every arithmetic candidate has
been tested and failed. It is that Link's pixels **take a different branch** on the M2 than on
the M3 Pro. The shader is 1883 lines of translated state machine with many `FSETP`/`ISETP`
comparisons, and a branch decided on a value that lands a ULP either side of its threshold will
diverge between two GPU generations with everything else identical. It also explains why the
probe of the *reciprocals* matched (both saturated) while the final colour did not, and why
none of the domain/precision/mip/depth knobs moved the core.

Next: use the probe as a path indicator rather than a value probe. Take a register written on
one side of a branch, probe with `LARECOMP_DBG_SCALE=1` and *without* the "lit" filter, and
compare the black-vs-nonblack pattern over Link between platforms - a different pattern is a
different code path, and the pc of the comparison that chose it is the bug. `LARECOMP_DBG_SCALE`
is in the tree for the small values on either side.

## Do not compare from build/pass_NNN.png directly

Both sides overwrite the canonical dump paths on every run: `build/pass_NNN.png` on the host and
`Documents/build/pass_NNN.png` in the device container. A probe run and a normal run write the
same names, so a "reference" dump silently becomes a probe dump and an analysis is invalidated
after the fact - this happened twice. `end_pass` knows the frame number and whether a probe is
active (`maxwell_dbg_hash`/`maxwell_dbg_pc`), so the dumps should carry a run-unique tag; until
then, copy each dump to a unique name in the same step that pulls or reads it, and never analyse
from the canonical path.

First path-indicator data point (device): probing `pc bd0 reg 6` leaves Link's body *black* -
zero equal-channel lit pixels in his crop - and `LARECOMP_DBG_SCALE=1000` changes nothing, so
`dbgv` is never written there and his fragments do not execute `pc bd0` at all. By contrast
`pc 9d8 reg 7` gives 7037 lit equal-channel pixels with max 255. So `pc bd0` sits on a branch
the iPad's fragments skip; whether the Mac's fragments take it is the test that would confirm or
kill the control-flow explanation. (macOS probe runs need retries: of five attempts, three
stalled in the title sequence and one closed its window.)

## What the player saw on the iPad (user-reported, 2 builds)

| build | Link's clothes | bloom | rest of scene |
|---|---|---|---|
| with the BC1 CPU decode installed | **black** | gone | (reported) normal |
| the current one (MUFU domain clamp, no BC1 decode) | **white** | present | normal |

Two conclusions follow, and they rule out the tempting story that the MUFU clamp fixed anything:

1. The clamp is *not* the fix: with it active the tunic is still blown out white and the bloom is
   still there. (The "white -> black" seen earlier was the BC1 decode breaking his albedo - that
   build's readback was shifted and mostly black, and with no white pixels left there was nothing
   for the bloom to spread - which is also a direct demonstration that his clothes' colour is
   driven by that albedo texture.)
2. His albedo is therefore *not* what is wrong on the real build: the texture readback is
   byte-identical between the platforms and the shader's own sampled albedo, probed at `pc 208`,
   is dark on the iPad (max 147, no white). So what blows out is the lighting/visibility factor
   applied to it.

That leaves a control-flow difference in the branchy translated state machine as the leading
mechanism - a loop bound (the shader walks a banked light table at a dynamic offset) or a branch
decided a ULP either side of its threshold - which is consistent with every arithmetic fix having
failed, with the probe showing saturated-but-equal reciprocals, and with the diff map's patchy,
screen-space pattern. `LARECOMP_NO_MUFU_LOG2/_SQRT/_RSQRT` are in the tree to lift the clamp one
op at a time if that line is revisited.

## First matched-state probe pair (both platforms, frame 12000, MarinTarinHouse)

Recipe that works on both: the original `LARECOMP_INPUT`, `LARECOMP_LAUNCHER_AUTOPLAY=1`,
`LARECOMP_WARP_ON_LOAD=MarinTarinHouse:MarinTarinHouse_01A`, `LARECOMP_DEBUG_FRAME=12000`,
`LARECOMP_DBG_FS_HASH=<fp>:<pc>:<reg>` (the wide repeated-`A` script runs smoothly on macOS but
keeps it at `level -`, so it never enters the game).

`pc bd0 reg 6` with `LARECOMP_DBG_SCALE=1000`: **both** platforms show `lit-grey = 0` over Link,
i.e. his fragments skip that branch on both - no control-flow divergence at that pc. The probe
and the comparison are therefore validated on a matched pair, and the path hypothesis is not
confirmed there.

What the pair does show is that the *scene* still differs at a matched frame and level: Link's
crop has mean 33.5 and 8685 black pixels on macOS against 16.9 and 10410 on the iPad. So the
room's lighting differs beyond any animation-phase effect, in the same patchy, screen-space way
the diff map showed - which points at the banked, screen-space light table the game builds into
guest memory (the fragment shader reads it as `cbr(cb10, r35 + n)` at a dynamic offset, and the
`[dispatch]` lines list `gmem`, so a compute shader writes it). `LARECOMP_PRECISE_MATH` already
covers the compute stage and did not fix the scene white, so the remaining untested lever there
is the compute library's own fast-math setting (`MTLCompileOptions.fastMathEnabled = NO` for
compute, which affects contraction and denormals rather than which instruction is used).

Compute-stage fast math is ruled out too: `LARECOMP_IEEE_COMPUTE` (MTLCompileOptions.fastMathEnabled
= NO for the compute library, which builds the screen-space light table) leaves the scene target at
17919 white pixels against 16969 without it and 3651 on macOS. So the light table's compute-stage
contraction/denormals are not the difference either. The player confirms the white bloom is still
there in the current build, i.e. none of the shipped changes touch the visible bug.

## The likely residual mechanism (from the player's two observations)

With every MUFU guard off the tunic is a *shapeless* glowing circle; with them on it is white
*with a visible shape* (player-confirmed, both on the iPad). That splits the bug in two:

- the **NaN** (a guard off means `log2`/`sqrt`/`rsqrt` of an out-of-domain argument) -> NaN in the
  HDR target -> the bloom smears it into a shapeless blob, so the *shape* comes from removing the NaN;
- a **finite over-bright value** that survives the guards and is what remains.

The guards' floor explains the second one: `rsqrt(fmax(x, 1e-30))` is **1e15** when the argument is
<= 0, i.e. finite but astronomically large - exactly "white with a visible shape" - where the Mac,
whose argument comes out a small positive, gets a modest value and shades correctly. So the argument
of at least one of these ops is on the other side of zero on the M2 than on the M3 Pro.

Bounding the guard does not fix that (any bound loose enough to keep legitimate cases still blows
out; any bound tight enough to fix it breaks them), so the argument itself has to be found: probe
the register that feeds each `rsqrt`/`log2`/`sqrt` - the pre-guard value - with
`LARECOMP_DBG_SCALE` large enough to see small numbers (and note that a *negative* probed value is
invisible in the unsigned HDR dump, which is why the probe needs an offset mode to show the sign).

Capping the reciprocal does **not** fix it: with `LARECOMP_MUFU_RCP_MAX=1e4` (on by default) the
device's scene target is 16845 white pixels with Link's crop still 13949 and max 255, against 16969
and 14073 before and 3651 / 0 on macOS. So the 1/0 -> +inf path (a degenerate half-precision
penumbra width fed to a reciprocal) is not the residual blow-out either.

Structural facts worth keeping, because they cut the search down:
- every `rsqrt` argument is `fma(v, v, acc)`, a running sum of squares - it cannot go negative, so
  the `rsqrt` guards never fire and the 1e15 floor theory is dead;
- the `sqrt` arguments are one `saturate(1 - r27)` (already in [0,1]) and six `hpack(hx(a) + hx(b))`
  half-precision sums, which is where a variance can come out a tiny negative;
- the guards together fixed the *NaN* (shapeless circle -> shaped white), so the residual is a
  genuinely large (>= 1) finite colour that survives every domain clamp. Nothing that clamps the
  guarded ops' degenerate cases touches it, which means the large value is produced *upstream* of
  them, not by them.

## First matched differential on the colour chain (frame 12000, MarinTarinHouse, both platforms)

`LARECOMP_DBG_FS_HASH=6804ba6e5340c6f9:22f0:0` - the final colour register just before the game's
own clamp, on the unconditional tail path every surviving fragment executes:

| | blob tile | probed px | mean | max |
|---|---|---|---|---|
| macOS | (1280,1216) | 709 | **14.9** | 88 |
| iPad | (1344,1152) | 4096 | **255.0** | 255 |

So the blow-out is already in that register: ~0.06-0.35 on the Mac against fully saturated on the
iPad, reproduced in a matched state. That is the anchor for walking backwards along the chain -
`pc 2250` -> `pc 22d0` -> `pc 20b0` -> `pc 2018` (`log2`) -> `pc 2130` (`exp2`) -> the amount of
light accumulated into `r0`/`r1`/`r2` - using the same recipe (original input script + fingerprint
probe), one pc per round, with `tools/cmp_probe.py` isolating the probed blob.
