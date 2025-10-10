import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// -----------------------------------------------------------------------------
// Configuration: fixed relative folders as requested
// -----------------------------------------------------------------------------
let inputHDRDir  = URL(fileURLWithPath: "./input_HDR/", isDirectory: true)
let inputSDRDir  = URL(fileURLWithPath: "./input_SDR/", isDirectory: true)
let outputDir    = URL(fileURLWithPath: "./output_HDR_with_gainmap/", isDirectory: true)

// Ensure folders exist (HDR input must exist; create output if missing)
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: inputHDRDir.path, isDirectory: &isDir), isDir.boolValue else {
    fputs("Missing folder: \(inputHDRDir.path)\n", stderr); exit(73)
}
if !FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir) {
    do { try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) }
    catch { fputs("Cannot create output dir: \(error)\n", stderr); exit(73) }
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

/// Return the canonical CGColorSpace name as String (or nil if untagged)
func csName(_ cs: CGColorSpace?) -> String? {
    guard let cs = cs, let name = cs.name else { return nil }
    return name as String
}

/// Measure a linear-light luminance peak proxy in extended linear P3 using CIAreaMaximum.
/// Renders the 1×1 RGBAf maximum and computes Y with Rec.709 weights.
func maxLuminanceHDR(from ciImage: CIImage, context: CIContext, linearCS: CGColorSpace) -> Float? {
    let filter = CIFilter.areaMaximum()
    filter.inputImage = ciImage
    filter.extent = ciImage.extent
    guard let out = filter.outputImage else { return nil }

    var px = [Float](repeating: 0, count: 4)
    context.render(out,
                   toBitmap: &px,
                   rowBytes: MemoryLayout<Float>.size * 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf,
                   colorSpace: linearCS)
    let r = px[0], g = px[1], b = px[2]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// --- Apple metadata mapping (inverse + forward) ---

/// Inverse of Apple's mapping: from linear headroom → stops → candidate (33,48) pairs.
/// Returns all valid candidates and also a default pick via a simple policy.
struct MakerAppleResult {
    struct Candidate {
        let maker33: Float    // 0.0 → "< 1.0" branch; 1.0 → ">= 1.0" branch
        let maker48: Float
        let stops: Float
        let branch: String
    }
    let stops: Float
    let candidates: [Candidate]
    let `default`: Candidate?
}

func makerAppleFromHeadroom(_ headroomLinear: Float) -> MakerAppleResult {
    // Apple's mapping supports up to 3 stops → headroom up to 8×
    let clamped = min(max(headroomLinear, 1.0), 8.0)
    let stops = log2f(clamped)
    var cs: [MakerAppleResult.Candidate] = []

    // maker33 < 1.0, maker48 ≤ 0.01: stops = -20*m48 + 1.8
    do { let m48 = (1.8 - stops)/20.0; if m48 >= 0, m48 <= 0.01 { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & <=0.01")) } }
    // maker33 < 1.0, maker48 > 0.01: stops = -0.101*m48 + 1.601
    do { let m48 = (1.601 - stops)/0.101; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & >0.01")) } }
    // maker33 ≥ 1.0, maker48 ≤ 0.01: stops = -70*m48 + 3.0
    do { let m48 = (3.0 - stops)/70.0; if m48 >= 0, m48 <= 0.01 { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & <=0.01")) } }
    // maker33 ≥ 1.0, maker48 > 0.01: stops = -0.303*m48 + 2.303
    do { let m48 = (2.303 - stops)/0.303; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & >0.01")) } }

    let preferred = cs.first { $0.maker33 >= 1.0 && $0.maker48 <= 0.01 }
                 ?? cs.first { $0.maker33 >= 1.0 }
                 ?? cs.first
    return .init(stops: stops, candidates: cs, default: preferred)
}

/// Forward mapping (Apple doc): maker(33,48) → stops (piecewise).
func stopsFromMakerApple(maker33: Float, maker48: Float) -> (stops: Float, branch: String)? {
    if maker33 < 1.0 {
        if maker48 <= 0.01 { return (-20.0*maker48 + 1.8, "<1 & <=0.01") }
        else               { return (-0.101*maker48 + 1.601, "<1 & >0.01") }
    } else {
        if maker48 <= 0.01 { return (-70.0*maker48 + 3.0, ">=1 & <=0.01") }
        else               { return (-0.303*maker48 + 2.303, ">=1 & >0.01") }
    }
}

/// Ex-post validation: verify that maker(33,48) re-generates the target stops/headroom.
struct MakerValidationDiffs {
    let targetStops: Float
    let forwardStops: Float
    let absStopsDiff: Float
    let targetHeadroom: Float
    let forwardHeadroom: Float
    let relHeadroomDiff: Float
    let branch: String
}

func validateMakerApple(headroomLinear: Float,
                        maker33: Float,
                        maker48: Float,
                        tolStopsAbs: Float = 0.01,
                        tolHeadroomRel: Float = 0.02) -> (ok: Bool, diffs: MakerValidationDiffs?) {
    let targetHeadroom = max(headroomLinear, 1.0)
    let targetStops = log2f(targetHeadroom)
    guard let (forwardStops, branch) = stopsFromMakerApple(maker33: maker33, maker48: maker48) else {
        return (false, nil)
    }
    let forwardHeadroom = powf(2.0, max(forwardStops, 0.0))
    let absStopsDiff = abs(forwardStops - targetStops)
    let relHeadroomDiff = abs(forwardHeadroom - targetHeadroom) / targetHeadroom
    let ok = (absStopsDiff <= tolStopsAbs) && (relHeadroomDiff <= tolHeadroomRel)
    return (ok, .init(targetStops: targetStops, forwardStops: forwardStops, absStopsDiff: absStopsDiff,
                      targetHeadroom: targetHeadroom, forwardHeadroom: forwardHeadroom,
                      relHeadroomDiff: relHeadroomDiff, branch: branch))
}

// Tonemap SDR via CIToneMapHeadroom using a source headroom ratio and target headroom = 1.0 (SDR)
func tonemapSDR(from hdr: CIImage, headroomRatio: Float) -> CIImage? {
    hdr.applyingFilter("CIToneMapHeadroom",
                       parameters: ["inputSourceHeadroom": headroomRatio,
                                    "inputTargetHeadroom": 1.0])
}

// -----------------------------------------------------------------------------
// Per-file processing setup
// -----------------------------------------------------------------------------

// Analysis context in extended linear P3 (for peak measurement)
let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctxLinearP3 = CIContext(options: [.workingColorSpace: linearP3,
                                      .outputColorSpace: linearP3])

// Encoding context (defaults OK)
let encodeCtx = CIContext()

// SDR encoding color space (Display P3) and required HDR source profile (Display P3 PQ)
let p3CS = CGColorSpace(name: CGColorSpace.displayP3)!
let hdrRequired = CGColorSpace.displayP3_PQ as String

// Find all PNG files in input_HDR
let hdrFiles: [URL]
do {
    hdrFiles = try FileManager.default
        .contentsOfDirectory(at: inputHDRDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    fputs("Cannot list input_HDR: \(error)\n", stderr); exit(73)
}

if hdrFiles.isEmpty {
    fputs("No PNG files found in \(inputHDRDir.path)\n", stderr)
    exit(0)
}

// -----------------------------------------------------------------------------
// Main loop: for each HDR PNG, try matching SDR or fall back to tonemapping
// -----------------------------------------------------------------------------
for hdrURL in hdrFiles {
    autoreleasepool {
        let basename = hdrURL.deletingPathExtension().lastPathComponent
        let sdrURL = inputSDRDir.appendingPathComponent(basename).appendingPathExtension("png")
        let outURL = outputDir.appendingPathComponent(basename).appendingPathExtension("heic")
        fputs("Processing \(basename)…\n", stderr)

        // Load HDR (with headroom preserved)
        guard let hdr = CIImage(contentsOf: hdrURL, options: [.expandToHDR: true]) else {
            fputs("  ! Cannot read HDR: \(hdrURL.path)\n", stderr); return
        }
        // Enforce HDR color space = Display P3 PQ
        guard let hdrCS = csName(hdr.colorSpace), hdrCS == hdrRequired else {
            fputs("  ! HDR colorspace not Display P3 PQ (got: \(csName(hdr.colorSpace) ?? "nil"))\n", stderr); return
        }

        // Measure linear headroom (peak luminance proxy) in linear P3
        guard let pic = maxLuminanceHDR(from: hdr, context: ctxLinearP3, linearCS: linearP3) else {
            fputs("  ! Cannot compute luminance peak\n", stderr); return
        }
        let picHeadroom = pic

        // Map the peak to a source headroom ratio for CIToneMapHeadroom
        let tonemapRatio: Float = 0.2
        let headroomRatio: Float = max(1.0, 1.0 + picHeadroom - powf(picHeadroom, tonemapRatio))

        // Choose pipeline: use provided SDR if present, otherwise tonemap
        let hasSDR = FileManager.default.fileExists(atPath: sdrURL.path)
        let sdrBase: CIImage
        if hasSDR {
            // --- Branch A: SDR provided ---
            guard let sdr = CIImage(contentsOf: sdrURL) else {
                fputs("  ! Cannot read SDR: \(sdrURL.path)\n", stderr); return
            }
            // Enforce identical orientation and size
            let hdrOrient = (hdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            let sdrOrient = (sdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            guard hdrOrient == sdrOrient else {
                fputs("  ! Orientation mismatch (HDR=\(hdrOrient), SDR=\(sdrOrient))\n", stderr); return
            }
            guard hdr.extent.size == sdr.extent.size else {
                fputs("  ! Size mismatch (HDR=\(hdr.extent.size), SDR=\(sdr.extent.size))\n", stderr); return
            }
            // Enforce SDR colorspace = Display P3
            guard let sdrCS = csName(sdr.colorSpace), sdrCS == CGColorSpace.displayP3 as String else {
                fputs("  ! SDR colorspace not Display P3 (got: \(csName(sdr.colorSpace) ?? "nil"))\n", stderr); return
            }
            sdrBase = sdr
        } else {
            // --- Branch B: Tonemap SDR from HDR ---
            guard let sdr = tonemapSDR(from: hdr, headroomRatio: headroomRatio) else {
                fputs("  ! Tonemapping failed\n", stderr); return
            }
            sdrBase = sdr
        }

        // Compute makerApple (33,48) from measured linear headroom
        let maker = makerAppleFromHeadroom(picHeadroom)
        guard let chosen = maker.default else {
            fputs("  ! No valid makerApple pair for headroom=\(picHeadroom)\n", stderr); return
        }
        
        // Using actual headroom effettivo (from metadata) for ex post validation
        let headroomUsedForMetadata = powf(2.0, max(maker.stops, 0.0))
        
        // Ex-post validation for consistency with target stops/headroom
        let val = validateMakerApple(headroomLinear: headroomUsedForMetadata,
                                     maker33: chosen.maker33,
                                     maker48: chosen.maker48,
                                     tolStopsAbs: 0.01,
                                     tolHeadroomRel: 0.02)
        if let d = val.diffs, !val.ok {
            fputs(String(format: "  ! makerApple validation failed (branch=%@, Δstops=%.4f, relΔ=%.2f%%)\n",
                         d.branch, d.absStopsDiff, d.relHeadroomDiff*100), stderr)
            return
        }
        
        if picHeadroom > 8.0 {
            fputs(String(format: "  • Headroom %.3f× exceeds metadata limit (8×). Clamped makerApple to 8×.\n", picHeadroom), stderr)
        }

        // Build a temporary in-memory HEIC from (SDR base, HDR) so the encoder computes a gain map
        let tmpOptions: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            .hdrGainMapAsRGB: false
        ]
        guard let tmpData = encodeCtx.heifRepresentation(of: sdrBase,
                                                         format: .RGB10,
                                                         colorSpace: p3CS,
                                                         options: tmpOptions) else {
            fputs("  ! Failed to build temp HEIC\n", stderr); return
        }
        // Extract the auxiliary HDR gain map image from the temporary HEIC
        guard let gainMap = CIImage(data: tmpData, options: [.auxiliaryHDRGainMap: true]) else {
            fputs("  ! Failed to extract gain map from temp HEIC\n", stderr); return
        }

        // Attach Maker Apple metadata to the SDR base that will be encoded
        var props = hdr.properties
        var makerApple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        makerApple["33"] = chosen.maker33
        makerApple["48"] = chosen.maker48
        props[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        let sdrWithProps = sdrBase.settingProperties(props)

        // Final export: SDR base (Display P3, 10-bit) + explicit gain map + high quality
        let exportOptions: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.97,
            CIImageRepresentationOption.hdrGainMapImage: gainMap,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        do {
            try encodeCtx.writeHEIFRepresentation(of: sdrWithProps,
                                                  to: outURL,
                                                  format: .RGB10,
                                                  colorSpace: p3CS,
                                                  options: exportOptions)
            fputs("  ✔ Wrote: \(outURL.path)\n", stderr)
        } catch {
            fputs("  ! Export failed: \(error)\n", stderr)
        }
    }
}

fputs("Done.\n", stderr)
