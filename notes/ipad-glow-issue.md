# Fixed: iPad Link glow from the Metal packed-half path

Resolved on the physical iPad Air M2 on 2026-10-15 by decoding packed half operands into fp32 by bits.
The original symptom and investigation are retained below.

## Original symptom

On the iPad, Link's own draw renders blown out to white while the same frame renders correctly on
macOS. The bloom then spreads the saturated pixels, which is the "glowing" the player sees: with the
domain guards in place he is **white but still shaped**; with them removed he becomes a **shapeless
glowing white circle** (NaN smeared by the bloom). Nothing else in the frame has the problem.

* iPad: Apple M2 (AGXMetalG14G), iPadOS
* Mac: Apple M3 Pro (AGXMetalG15 class), macOS
* Both run the same build, the same save, the same inputs, the same render scale.

## Reproduction

Device (`xcrun devicectl device process launch --console --terminate-existing -e '{...}'`):

```json
{"LARECOMP_LAUNCHER_AUTOPLAY":"1",
 "LARECOMP_INPUT":"7000:L:180,7000:R:180,8000:DOWN:10,8150:DOWN:10,8300:DOWN:10,8500:A:20,9000:A:20",
 "LARECOMP_WARP_ON_LOAD":"MarinTarinHouse:MarinTarinHouse_01A",
 "LARECOMP_DEBUG_FRAME":"12000",
 "LARECOMP_SCALE":"1.4229"}
```

Host: the same, plus `LARECOMP_HIDDEN=1`. Note the **original** input script; a wide repeated-`A`
variant runs smoothly on macOS but leaves it at `level -`, so it never enters the game.

Metric: in the scene target (pass dump `pass_006`, the frame *before* the bloom), inside Link's crop
(1180,980)-(1560,1300) of the 2732x1537 dump:

| | whole scene white (>245) | Link crop white | crop max |
|---|---|---|---|
| macOS | 3651 | **0** | 143 |
| iPad | 16969 | **14073** | 255 |

**Always measure the scene target, not `LARECOMP_WINDOW_SHOT`** - the window shot contains the
bloom, so a change that only shrinks the halo looks like a partial fix.

## Proven identical across the two GPUs

Pass sequence and sizes (27 passes, matched 1:1); draw order, counts, shader fingerprints, render
target, viewport, attributes, vertex streams; the generated **MSL** of Link's body shader
(`6804ba6e5340c6f9`, dumped from the device and diffed); fragment uniforms f0-f17 (6 floats differ
in f1, in a part the shader never reads); the draw's textures (1024x1024 BC1 albedo, two 512x512
BC4 masks) and their level 0; vertex uniforms (camera by ~0.15 deg, one scalar).

The texture fetch itself is provably correct on the iPad: `LARECOMP_DBG_FS_HASH=6804ba6e5340c6f9:208:8`
probes the sampled albedo and gives a dark value (max 147, no white pixels).

## Ruled out by experiment

| candidate | evidence |
|---|---|
| per-draw highlight tint | `LARECOMP_LOG_TINT` never fires without a rando seed |
| BC1 / sRGB / mips | readback byte-identical; `LARECOMP_LOD_MAX=0` only shrinks the halo |
| shadow comparison | `LARECOMP_NO_SHADOW` no effect |
| Metal fast math (fragment) | `fastMathEnabled=NO` no effect |
| Metal fast math (compute) | `LARECOMP_IEEE_COMPUTE` no effect (17919 vs 16969) |
| IEEE transcendentals | `LARECOMP_PRECISE_MATH` no effect (17687 vs 16969) |
| out-of-domain log2/sqrt/rsqrt | guards fix the NaN (circle -> shaped white) but not the residual |
| rsqrt floor (1e15) | every `rsqrt` argument is `fma(v,v,acc)`, a sum of squares: the guards never fire |
| reciprocal of a degenerate width | `LARECOMP_MUFU_RCP_MAX` no effect (16845 vs 16969) |
| depth-scale path | `LARECOMP_NO_DEPTH_SCALE` only shrinks the halo |
| uninitialized registers | the MSL zero-initializes every register |
| the albedo fetch | probe above: correct and dark |

## Current state

### Verified fix: decode packed half operands by bits (2026-10-15)

The Metal `hx()` helper now uses the GLSL backend's bit-based half-to-float conversion instead of
`float2(as_type<half2>(v))`. This removes native half operands from the following lighting arithmetic.
The exact compiler lowering was not disassembled, but replacing this conversion fixes the physical
M2 rendering while retaining the healthy M3 Pro output. No texture replacement or colour clamp is
needed for the fix.

Matched frame 12000, before bloom, with the original recipe above:

| build | scene white (>245) | Link crop white | crop max |
|---|---:|---:|---:|
| previous iPad reciprocal-cap build | 16845 | 13949 | 255 |
| fixed iPad M2 | 3670 | **0** | 145 |
| fixed Mac M3 Pro | 3651 | **0** | 143 |

The fixed iPad's displayed frame was also inspected: Link has green clothing and no white halo.
A second device run walked him outside into `Field`; his tunic and shield also render correctly
in daylight (`ipad-outdoor-window.png`, `ipad-outdoor.log`), and the run exited with code 0.
Evidence: `build/glow-half/ipad-candidate-scene.png`, `ipad-candidate-window.png`,
`scene-comparison.json`, and `ipad-candidate.log`. The app completed the capture and exited with
code 0. Saves and settings were copied to scratch locations before launching.

The numerical check is reproducible with `make build/test_metal_half && build/test_metal_half`.
All 65,536 half encodings and finite paired-lane round trips pass on the M3 Pro. The test also
renders synthetic fragment probes with positive, negative and zero scales, a signed offset, and
an unvisited probe PC. The signed-offset GLSL probe compiles to Vulkan 1.3 SPIR-V with `glslc`.
Link's reconstructed body shader and four captured compute programs compile; macOS and signed
iPadOS builds succeed. GPU access is required for the numerical test.

`LARECOMP_DBG_OFFSET=0.5` now maps a zero-valued probe to mid-grey; combine with
`LARECOMP_DBG_SCALE` to show small signed inputs. The transform is applied only when the probe PC
executes, so skipped branches remain black even with a negative or zero scale. It works in both
MSL and GLSL. For a matched device/host probe, `6804ba6e5340c6f9:878:41` probes a signed
variance term before its square root; probe `898:40` for the other term. Use the same scale and
offset on both platforms and preserve each scene dump under a unique run name immediately.

### Historical state before the packed-half fix

The guards removed a **NaN** (that is what destroyed his silhouette). What remains is a **genuinely
large (>= 1) finite colour that survives every domain clamp**, so it is produced *upstream* of the
guarded ops rather than by their degenerate cases - which excludes the whole "clamp the degenerate
input" family of fixes by construction. Link's own crop already has the blow-out in the register at
the end of the shader's tail (`pc 22f0 r0`, probed: 8410 lit-grey pixels, max 255).

Two leading explanations remain:

1. **Control flow** in the branchy translated state machine (`switch (pc)`): a branch decided a ULP
   either side of its threshold on the two GPU generations. The probe doubles as a path indicator -
   a pc on an untaken branch renders black - and `pc bd0` is skipped on *both* platforms, so the
   walk needs pcs on the unconditional path.
2. **A compiler difference**: the iPad and Mac run different OS versions, hence different Metal
   compilers, which for a shader this numerically fragile can legitimately produce different code
   from identical MSL.

The room's lighting also differs at a matched frame, in the same patchy, screen-space way (crop mean
33.5 vs 16.9), which points at the banked screen-space light table the game builds into guest memory
(the shader reads it as `cbr(cb10, r35 + n)` at a dynamic offset; the `[dispatch]` lines list `gmem`).

## Tooling in the tree

* `LARECOMP_DBG_FS_HASH=<fingerprint>:<pc hex>:<reg>` - probe one register by content fingerprint
  (the address form matches the wrong shader: the heap reuses code blocks within a run, which made
  macOS runs crawl at 40-60 s/frame on a launcher shader). `reg+1000`/`+2000` read the low/high f16
  lane. `LARECOMP_DBG_SCALE` scales the value out; `LARECOMP_DBG_OFFSET` adds a signed-view offset
  after scaling (0.5 places zero at mid-grey). Unvisited probe PCs remain black.
* `LARECOMP_MUFU_FLOOR`, `LARECOMP_MUFU_RCP_MAX`, `LARECOMP_NO_MUFU_LOG2/_SQRT/_RSQRT`,
  `LARECOMP_PRECISE_MATH`, `LARECOMP_IEEE_COMPUTE`, `LARECOMP_LOD_MAX`, `LARECOMP_DUMP_MIP`.
* `tools/cmp_passes.py`, `tools/cmp_draw_inputs.py`, `tools/cmp_probe.py` (the last isolates the
  probed blob as the densest 64x64 tile of equal-channel pixels; a whole-image histogram is dominated
  by grey scene pixels and the black border).
* `notes/ios-port.md` holds the full log of the investigation, including the dump-hygiene trap: both
  sides overwrite `build/pass_NNN.png` and `Documents/build/pass_NNN.png` on every run, so each dump
  must be copied to a unique name in the same step that reads it.
