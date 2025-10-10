# HDR2gainmap

A tiny command-line tool that turns HDR stills into **10-bit HEIC with an Apple-compatible gain map**.

- **Use your own SDR base** (PNG in Display P3) to control SDR appearance, **or**
- **Generate the SDR base via tone-mapping** from the HDR image.

Under the hood it:
- validates color spaces, orientation, and dimensions,
- estimates **linear headroom** in extended linear P3,
- derives **Apple Maker** metadata keys `33` and `48` from that headroom (Apple’s piecewise mapping, clamped to **3 stops / 8×**),
- performs a temporary in-memory HEIC to **extract the encoder’s gain map**,
- writes the final **HEIC (10-bit Display P3)** = SDR base **+** explicit gain map **+** Maker Apple metadata.

---

## Features

- ✅ Apple Photos–friendly HEIC with gain map (survives iCloud sync).
- ✅ Two workflows: *HDR+SDR pair* or *HDR-only with tone-mapped SDR*.
- ✅ Strict validation (color space, orientation, size).
- ✅ Maker Apple metadata computed from measured headroom with ex-post validation.
- ✅ Batch processing of all `*.png` in `./input_HDR`.

---

## Requirements

- **macOS 15+** (for `CIToneMapHeadroom` and HDR gain-map options).
- Xcode Command Line Tools (for `swiftc`).
- Inputs are **PNG** files (HDR: Display P3 PQ, SDR: Display P3).

---

## Folder Layout & Input Specs

```
./input_HDR/                # HDR PNGs (required)
./input_SDR/                # optional SDR PNGs (same basename as HDR)
./output_HDR_with_gainmap/  # output HEICs
```

### HDR input (required)

- **Format:** PNG  
- **Color space:** Display P3 **PQ** (tagged)  
- **Naming:** `name.png` → output becomes `name.heic`  
- **Tip:** If your HDR PNGs are untagged, export with an explicit Display P3 PQ profile.

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
3. Measure the peak in **linear P3** and compute **linear headroom**.
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

(If you really want the best results, create a virtual copy of the RAW image in LrC and adjust it
as an SDR image. Export it to `./input_SDR/` and it will be used as the base image)

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

### Run

```bash
./hdr2gainmap
```

The program logs progress to **stderr** and writes `*.heic` files to:

```
./output_HDR_with_gainmap/
```

---

## Output

- **HEIC**, 10-bit (`RGB10`) **Display P3** base image.  
- Embedded **gain map** (explicit, platform-native; not forced to RGB payload).  
- **Maker Apple** metadata keys `33` and `48`, consistent with the measured (clamped) headroom.

---

## Notes & Limitations

- **Maximum metadata headroom** (from the Maker Apple mapping) is **3 stops = 8×**.  
  If the measured headroom exceeds 8×, the tool **clamps for metadata only**.  
  The **gain map itself** may encode wider dynamics; the clamp keeps metadata valid.
- **Color tags are enforced**:  
  - HDR must be **Display P3 PQ**.  
  - SDR (if provided) must be **Display P3**.  
  Files without tags or with mismatched sizes/orientations are skipped with an error.
- Requires **macOS 15+** (`CIToneMapHeadroom`, gain-map APIs).

---

## Compatibility

- **Tested** on **Intel-based Mac** running **macOS 15.7**.  
- On some **Apple Silicon** systems, if you hit export issues, try switching the final call from:
  ```swift
  writeHEIFRepresentation(...)
  ```
  to:
  ```swift
  writeHEIF10Representation(...)
  ```
  (This may resolve encoder mismatches on certain configurations.)

---

## Credits

Huge thanks to **chemharuka** for prior art and inspiration:  
<https://github.com/chemharuka/toGainMapHDR>

This project adapts and extends those ideas with:
- automatic Maker Apple metadata derivation (forward + inverse mapping),
- strict validation,
- optional SDR-base workflow,
- batch processing, and an Apple-friendly export path.

---

## License

MIT
