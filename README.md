# HDR2gainmap

A tiny command-line tool that turns HDR stills into **10-bit HEIC with an Apple-compatible gain map**.

- Use your own **SDR base** (PNG in Display P3) to control SDR appearance, **or**
- Let the tool **tone-map** the SDR base from the HDR image.
- Derives **Maker Apple** metadata keys `33` and `48` from measured headroom (Apple’s piecewise mapping, clamped to **3 stops / 8×**).
- Can compute headroom via a **robust percentile** (recommended) or a **legacy max-based** method.
- Can emit a **clip mask** PNG and/or a **masked SDR overlay** to visualize clipped areas.

---

## Features

- ✅ Apple Photos–friendly **HEIC (10-bit Display P3)** with **embedded gain map** (works across iCloud).
- ✅ Two workflows: *HDR+SDR pair* **or** *HDR-only with tone-mapped SDR*.
- ✅ **Percentile-based headroom** (`--peakPercentile`) for robust peak detection.
- ✅ **Dry-run** mode (`--tonemap_dryrun`) prints headroom & clip stats without writing HEICs.
- ✅ Optional **clip mask** (`--emitClipMask`) and **masked overlay** (`--emitMaskedImage`) for debugging.
- ✅ Strict validation (color space, orientation, size).
- ✅ **Maker Apple** metadata computed and **validated ex-post**.
- ✅ Batch processing of all `*.png` in `./input_HDR`.

---

## Requirements

- **macOS 15+** (uses `CIToneMapHeadroom` and HDR gain-map write options).
- Xcode Command Line Tools (for `swiftc`).
- Inputs are **PNG** files:
  - **HDR**: Display P3 **PQ** (tagged).
  - **SDR** (optional): Display **P3** (tagged).

---

## Folder Layout & Input Specs

```
./input_HDR/                # HDR PNGs (required)
./input_SDR/                # optional SDR PNGs (same basename as HDR)
./output_HDR_with_gainmap/  # output HEICs (+ optional debug PNGs)
```

### HDR input (required)

- **Format:** PNG  
- **Color space:** Display P3 **PQ** (tagged)  
- **Naming:** `name.png` → output becomes `name.heic`  
- **Tip:** If your HDR PNGs are untagged, re-export with an explicit Display P3 PQ profile.

### SDR input (optional, per image)

- **Format:** PNG  
- **Color space:** Display **P3** (tagged)  
- **Constraints:** **same basename**, **same dimensions**, **same orientation** as the HDR  
- If present, it is used as the **SDR base**. If absent, the tool **tone-maps** the SDR base from HDR.

---

## How It Works (high-level)

1. Scan `./input_HDR/` for `*.png`.
2. For each HDR:
   - If `./input_SDR/<same-name>.png` exists → **use it** (after checks).
   - Otherwise → **tone-map** the HDR via `CIToneMapHeadroom` to create the SDR base.
3. Measure the peak in **linear P3** and compute **linear headroom**:
   - **Robust percentile** (e.g., 99.5th) on linear luminance **or**
   - **Legacy max** + softening curve (default `tonemapRatio = 0.2`).
4. Convert headroom → **Maker Apple** keys (`33`, `48`) using Apple’s piecewise mapping  
   *(clamped to **3 stops** → **8×** headroom; validated ex-post).*  
5. Build a temporary in-memory HEIC from (SDR base + HDR) so Core Image **generates a gain map**.
6. Extract the **gain map** as an auxiliary image.
7. Write the final **HEIC (10-bit Display P3)** with:
   - SDR base,  
   - explicit **gain map**,  
   - **Maker Apple** metadata.

---

## Lightroom Classic (RAW → HDR) Workflow Tips

If you develop RAW in **Adobe Lightroom Classic** on an HDR display:

1. Enable **“Preview for SDR displays”** while editing HDR to fine-tune the SDR look.
2. Create **two export presets**:
   - **HDR preset** → exports **PNG HDR** to `./input_HDR/`  
     - Color space: **HDR Display P3 (PQ)**
   - **SDR preset** → exports **PNG SDR** to `./input_SDR/`  
     - Color space: **Display P3**  
     - **Same** pixel dimensions and orientation as the HDR
3. Apply both presets to all RAWs you want to publish with a gain map.  
   This gives you control over the SDR base embedded in the HEIC.

**Alternative:** Only export the **HDR PNG** to `./input_HDR/`.  
The tool will **tone-map** the SDR base automatically.

> Tip: For the very best SDR control, create a virtual copy of the RAW as SDR, adjust it, and export it to `./input_SDR/`.

---

## Build & Run

### Compile

```bash
xcrun --sdk macosx swiftc -O -o hdr2gainmap BatchHDR2HEIC.swift
```

### Prepare folders

```bash
mkdir -p input_HDR input_SDR output_HDR_with_gainmap
```

### Run (basic)

```bash
./hdr2gainmap
```

Outputs to:

```
./output_HDR_with_gainmap/
```

---

## Command-line Options

```
Usage:
  hdr2gainmap [--suffix <text>] [--peakPercentile [value]] [--tonemap_dryrun]
              [--emitClipMask] [--emitMaskedImage [color]] [--debug]

Options:
  --suffix <text>           Suffix appended to output filename (e.g. "_sdrtm")
  --peakPercentile [value]  Use percentile-based peak (default 99.5 if value omitted)
  --tonemap_dryrun          Only compute headroom + clipped fraction; no HEIC output
  --emitClipMask            Also write a black/white PNG mask of clipped pixels
  --emitMaskedImage [color] Also write an SDR image with clipped pixels painted solid
                            Color can be a name (red, magenta, violet) or #RRGGBB (default: magenta)
  --debug                   Print verbose debug messages
  --help                    Show this message
```

### Examples

- **HDR-only, robust percentile (default 99.5th), clip mask + overlay, verbose:**
  ```bash
  ./hdr2gainmap --peakPercentile --emitClipMask --emitMaskedImage red --debug
  ```

- **Explicit percentile 99.0th, just HEICs, suffix appended:**
  ```bash
  ./hdr2gainmap --peakPercentile 99.0 --suffix _p99
  ```

- **Dry run (no files written), report headroom & clipped fraction:**
  ```bash
  ./hdr2gainmap --tonemap_dryrun --peakPercentile
  ```

---

## Output

- **HEIC**, 10-bit (`RGB10`) **Display P3** base image.  
- Embedded **gain map** (explicit, platform-native; not forced to RGB payload).  
- **Maker Apple** metadata keys `33` and `48`, consistent with the measured (clamped) headroom.  
- Optional debug PNGs:
  - `*_clipmask.png` (white = clipped; black = not clipped),
  - `*_clippedOverlay.png` (SDR with clipped pixels painted a solid color).

---

## Verify the Gain Map (Important)

On some systems (e.g., certain **Apple Silicon** models or **macOS** versions), the encoder may silently emit **SDR-only HEICs without a gain map**. To **verify**:

1. Download Adobe’s **Gain Map Demo App for macOS**:  
   <https://www.adobe.com/go/gainmap_demoapp_mac>
2. Open your output `.heic` files in the app and confirm a **gain map is present**.
3. If the gain map is missing:
   - Try switching the final write from:
     ```swift
     writeHEIFRepresentation(...)
     ```
     to:
     ```swift
     writeHEIF10Representation(...)
     ```
     which can resolve encoder differences on some configurations.
   - Re-run with `--debug` and open an issue including your **macOS version**, **Mac model (Intel/Silicon)**, and the **debug log**.

---

## Notes & Limitations

- **Maximum metadata headroom** in the Maker Apple mapping is **3 stops (8×)**.  
  If the measured headroom exceeds 8×, the tool **clamps metadata only** (the gain map can still encode broader dynamics).
- **Color tags are enforced**:
  - HDR must be **Display P3 PQ** (tagged).
  - SDR (if provided) must be **Display P3** (tagged).
  - Files with mismatched size/orientation are rejected.
- **Percentile headroom** uses a normalized linear-luminance histogram (up to **2048 bins**) in extended linear P3.
- The **legacy max-based** method applies a softening curve with `tonemapRatio = 0.2` by default.

---

## Compatibility

- **Tested** on **Intel-based Mac** running **macOS 15.7**.  
- On some **Apple Silicon** systems, switching to `writeHEIF10Representation` may be required (see above).

---

## Credits

Huge thanks to **chemharuka** for prior art and inspiration:  
<https://github.com/chemharuka/toGainMapHDR>

This project adapts and extends those ideas with:
- automatic Maker Apple metadata derivation (forward + inverse mapping),
- robust percentile headroom (optional) + legacy path,
- strict validation & ex-post metadata checks,
- masks/overlays for debugging,
- batch processing, and an Apple-friendly export path.

---

## License

MIT
