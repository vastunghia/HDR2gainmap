import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// -----------------------------------------------------------------------------
// Configuration
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

// number of bins when building histograms (max allowed by CIAreaHistogram is 2048)
let kCIHistogramMaxBins = 2048

// -----------------------------------------------------------------------------
// CLI parsing with strict validation
// -----------------------------------------------------------------------------

struct Options {
    var outputSuffix: String = ""
    var usePercentile: Bool = false
    var peakPercentile: Float = 99.5
    var tonemapDryRun: Bool = false
    var emitClipMask: Bool = false
    var emitMaskedImage: Bool = false
    var maskedColor: String = "magenta"
    var debug: Bool = false
}

@discardableResult
func printUsage(_ prog: String) -> Int32 {
    fputs("""
    Usage:
      \(prog) [--suffix <text>] [--peakPercentile [value]] [--tonemap_dryrun] [--emitClipMask] [--emitMaskedImage [color]] [--debug]

    Options:
      --suffix <text>           Suffix appended to output filename (e.g. "_sdrtm")
      --peakPercentile [value]  Use percentile-based peak (default 99.5 if value omitted)
      --tonemap_dryrun          Only compute headroom + clipped fraction; no HEIC output
      --emitClipMask            Also write a black/white PNG mask of clipped pixels
      --emitMaskedImage [color] Also write an SDR image with clipped pixels painted solid
                                Color can be a name (red, magenta, violet) or #RRGGBB (default: magenta)
      --debug                   Print verbose debug messages
      --help                    Show this message

    """, stderr)
    return 64
}

func parseOptions(_ argv: [String]) -> Options {
    var opts = Options()
    let allowed = Set([
        "--suffix","--peakPercentile","--tonemap_dryrun",
        "--emitClipMask","--emitMaskedImage","--debug","--help"
    ])
    var i = 1
    let n = argv.count
    let prog = (argv.first ?? "prog")

    while i < n {
        let tok = argv[i]
        guard tok.hasPrefix("-") else { fputs("Unknown positional argument: \(tok)\n", stderr); exit(printUsage(prog)) }
        if tok == "--help" { exit(printUsage(prog)) }
        guard allowed.contains(tok) else { fputs("Unknown option: \(tok)\n", stderr); exit(printUsage(prog)) }

        switch tok {
        case "--suffix":
            guard i+1 < n, !argv[i+1].hasPrefix("-") else { fputs("Option --suffix requires a value.\n", stderr); exit(printUsage(prog)) }
            var suffix = argv[i+1]
            if !suffix.isEmpty && !suffix.hasPrefix("_") && !suffix.hasPrefix("-") { suffix = "_" + suffix }
            opts.outputSuffix = suffix
            i += 2

        case "--peakPercentile":
            if i+1 < n, !argv[i+1].hasPrefix("-") {
                guard let p = Float(argv[i+1]), p > 0, p <= 100 else { fputs("Invalid value for --peakPercentile: \(argv[i+1])\n", stderr); exit(printUsage(prog)) }
                opts.peakPercentile = p
                opts.usePercentile = true
                i += 2
            } else {
                opts.usePercentile = true
                i += 1
            }

        case "--tonemap_dryrun":
            opts.tonemapDryRun = true
            i += 1

        case "--emitClipMask":
            opts.emitClipMask = true
            i += 1

        case "--emitMaskedImage":
            opts.emitMaskedImage = true
            if i+1 < n, !argv[i+1].hasPrefix("-") {
                opts.maskedColor = argv[i+1]; i += 2
            } else { i += 1 }

        case "--debug":
            opts.debug = true
            i += 1

        default:
            fputs("Unhandled option: \(tok)\n", stderr); exit(printUsage(prog))
        }
    }
    return opts
}

let options = parseOptions(CommandLine.arguments)

@inline(__always)
func dbg(_ message: @autoclosure () -> String) {
    if options.debug { fputs(message(), stderr) }
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

/// Parse a color string into CIColor. Accepts simple names or "#RRGGBB".
func parseColor(_ s: String) -> CIColor {
    let lower = s.lowercased()
    switch lower {
    case "red":     return CIColor(red: 1, green: 0, blue: 0)
    case "magenta": return CIColor(red: 1, green: 0, blue: 1)
    case "violet":  return CIColor(red: 0.56, green: 0, blue: 1)
    default:
        if lower.hasPrefix("#"), lower.count == 7 {
            let rStr = String(lower.dropFirst().prefix(2))
            let gStr = String(lower.dropFirst(3).prefix(2))
            let bStr = String(lower.dropFirst(5).prefix(2))
            let r = CGFloat(Int(rStr, radix: 16) ?? 255) / 255.0
            let g = CGFloat(Int(gStr, radix: 16) ?? 0)   / 255.0
            let b = CGFloat(Int(bStr, radix: 16) ?? 255) / 255.0
            return CIColor(red: r, green: g, blue: b)
        }
        // Fallback: magenta
        return CIColor(red: 1, green: 0, blue: 1)
    }
}

/// Return the canonical CGColorSpace name as String (or nil if untagged)
func csName(_ cs: CGColorSpace?) -> String? {
    guard let cs = cs, let name = cs.name else { return nil }
    return name as String
}

/// Measure a linear-light luminance peak proxy in extended linear P3 using CIAreaMaximum.
/// Renders the 1×1 RGBAf maximum and computes Y with Rec.709 weights.
func maxLuminanceHDR(from ciImage: CIImage,
                     context: CIContext,
                     linearCS: CGColorSpace) -> Float? {
    // 1) build linear luminance in R
    let yImg = linearLuma(ciImage)

    // 2) area max on Y
    let filter = CIFilter.areaMaximum()
    filter.inputImage = yImg
    filter.extent = yImg.extent
    guard let out = filter.outputImage else { return nil }

    // 3) read back R channel (Y peak)
    var px = [Float](repeating: 0, count: 4)
    context.render(out,
                   toBitmap: &px,
                   rowBytes: MemoryLayout<Float>.size * 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf,
                   colorSpace: linearCS)

    let yPeak = max(0, px[0]) // R holds Y
    return yPeak
}

// --- percentile-based headroom measurement ---

/// Put *linear* luminance Y into the *R* output channel; zero-out G/B; keep A=1.
/// Formula (linear): Y = 0.2126*R + 0.7152*G + 0.0722*B
func linearLuma(_ src: CIImage) -> CIImage {
    let m = CIFilter.colorMatrix()
    m.inputImage = src
    // ColorMatrix uses a 4x4 where *columns* are rVector/gVector/bVector/aVector.
    // Output = rVec*in.r + gVec*in.g + bVec*in.b + aVec*in.a + bias.
    // We want: out.R = 0.2126*in.r + 0.7152*in.g + 0.0722*in.b; out.G = 0; out.B = 0; out.A = 1.
    m.rVector   = CIVector(x: 0.2126, y: 0,      z: 0,      w: 0) // in.r -> out.R
    m.gVector   = CIVector(x: 0.7152, y: 0,      z: 0,      w: 0) // in.g -> out.R
    m.bVector   = CIVector(x: 0.0722, y: 0,      z: 0,      w: 0) // in.b -> out.R
    m.aVector   = CIVector(x: 0,      y: 0,      z: 0,      w: 1) // out.A = in.a*1
    m.biasVector = CIVector(x: 0,     y: 0,      z: 0,      w: 0)
    return m.outputImage!
}

/// Linear-luminance percentile (robust peak) in extended linear P3.
/// Steps:
///  1) Measure absolute max luminance (linear) with CIAreaMaximum → absMax
///  2) Build a linear-luma image (Y in R channel)
///  3) Normalize that Y by dividing by absMax → domain ∈ [0,1]
///  4) Histogram on normalized Y; take the requested percentile on the CDF
///  5) Map the percentile back to absolute luminance: y_p = v_norm * absMax
///  6) Headroom = max(y_p, 1.0)
func percentileHeadroom(from ciImage: CIImage,
                        context: CIContext,
                        linearCS: CGColorSpace,
                        bins: Int = 1024,
                        percentile: Float = 99.5) -> Float? {
    let binCount = min(max(bins, 1), 2048)

    guard let absMax = maxLuminanceHDR(from: ciImage, context: context, linearCS: linearCS),
          absMax > 0 else { return 1.0 }

    var yImg = linearLuma(ciImage)

    // Normalize Y by absMax → bring HDR range into [0,1]
    let norm = CIFilter.colorMatrix()
    norm.inputImage = yImg
    let s = CGFloat(1.0) / CGFloat(absMax)
    norm.rVector   = CIVector(x: s, y: .zero, z: .zero, w: .zero) // scale R (Y lives in R)
    norm.gVector   = CIVector(x: .zero, y: 1.0,  z: .zero, w: .zero)
    norm.bVector   = CIVector(x: .zero, y: .zero, z: 1.0,  w: .zero)
    norm.aVector   = CIVector(x: .zero, y: .zero, z: .zero, w: 1.0)
    norm.biasVector = CIVector(x: .zero, y: .zero, z: .zero, w: .zero)
    yImg = norm.outputImage!

    let hist = CIFilter.areaHistogram()
    hist.inputImage = yImg
    hist.extent = yImg.extent
    hist.count = binCount
    hist.scale = 1.0

    guard let histImage = hist.outputImage else { return nil }

    var buf = [Float](repeating: 0, count: binCount * 4)
    context.render(histImage,
                   toBitmap: &buf,
                   rowBytes: MemoryLayout<Float>.size * 4 * binCount,
                   bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                   format: .RGBAf,
                   colorSpace: linearCS)

    var cdf = [Double](repeating: 0, count: binCount)
    var total: Double = 0
    for i in 0..<binCount {
        let c = Double(max(0, buf[i*4 + 0]))
        total += c
        cdf[i] = total
    }
    guard total > 0 else { return 1.0 }
    
    var k = 0
    let target = Double(percentile) / 100.0 * total
    while k < binCount && cdf[k] < target { k += 1 }
    if k >= binCount { k = binCount - 1 }

    // Bin center in [0,1]
    let vNorm = (Double(k) + 0.5) / Double(binCount)
    let yPercentile = Float(vNorm) * absMax
    
    // DEBUG: print internals
    let reached = cdf[k] / total
    dbg(String(format:
      "    [percentileHeadroom-debug] bins=%d absMax=%.6f target=%.1f%% k=%d  vNorm=%.6f  CDF=%.4f  yPercentile=%.6f headroom=%.6f\n",
      binCount, absMax, Double(percentile), k, vNorm, reached, Double(yPercentile), Double(max(yPercentile, 1.0))
    ))

    return max(yPercentile, 1.0)
}

/// Estimate the fraction of HDR pixels whose *linear luminance* exceeds a given threshold
/// (threshold = inputSourceHeadroom). Works in extended linear P3.
/// Strategy:
///  - Build a luminance (linear) image via CIColorMatrix
///  - Compute histogram (CIAreaHistogram) with `bins` buckets
///  - Map threshold to a histogram bin using the absolute max luminance (CIAreaMaximum)
///  - Return fraction = (#pixels above threshold) / (total #pixels)
/// IMPORTANT: normalize by absMax to avoid HDR clipping in CIAreaHistogram (domain is [0,1]).
func fractionAboveHeadroomThreshold(from ciImage: CIImage,
                                    context: CIContext,
                                    linearCS: CGColorSpace,
                                    thresholdHeadroom: Float,
                                    bins: Int = 1024)
-> (fraction: Double, clippedPixels: Double, totalPixels: Double)? {

    let binCount = min(max(bins, 1), 2048)

    // 1) Absolute max luminance (linear)
    guard let absMax = maxLuminanceHDR(from: ciImage, context: context, linearCS: linearCS),
          absMax > 0 else { return nil }

    // 2) Luminance in R
    var yImg = linearLuma(ciImage)

    // 3) Normalize Y by absMax (bring to [0,1] like in percentile)
    let norm = CIFilter.colorMatrix()
    norm.inputImage = yImg
    let s = CGFloat(1.0) / CGFloat(absMax)
    norm.rVector   = CIVector(x: s, y: .zero, z: .zero, w: .zero)
    norm.gVector   = CIVector(x: .zero, y: 1.0,  z: .zero, w: .zero)
    norm.bVector   = CIVector(x: .zero, y: .zero, z: 1.0,  w: .zero)
    norm.aVector   = CIVector(x: .zero, y: .zero, z: .zero, w: 1.0)
    norm.biasVector = CIVector(x: .zero, y: .zero, z: .zero, w: .zero)
    yImg = norm.outputImage!

    // 4) Histogram on normalized Y
    let hist = CIFilter.areaHistogram()
    hist.inputImage = yImg
    hist.extent = yImg.extent
    hist.count = binCount
    hist.scale = 1.0

    guard let histImage = hist.outputImage else { return nil }

    var buf = [Float](repeating: 0, count: binCount * 4)
    context.render(histImage,
                   toBitmap: &buf,
                   rowBytes: MemoryLayout<Float>.size * 4 * binCount,
                   bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                   format: .RGBAf,
                   colorSpace: linearCS)

    // 5) CDF on R
    var cdf = [Double](repeating: 0, count: binCount)
    var totalHist: Double = 0
    for i in 0..<binCount {
        let c = Double(max(0, buf[i*4 + 0]))
        totalHist += c
        cdf[i] = totalHist
    }
    guard totalHist > 0 else { return (0.0, 0.0, 0.0) }

    // 6) Map absolute threshold → normalized domain, then → bin
    //    thrHeadroom is absolute (e.g. 5.136); thrNorm ∈ [0,1].
    let thrNorm = min(max(Double(thresholdHeadroom / absMax), 0.0), 1.0)
    var thrBin = Int(floor(thrNorm * Double(binCount)))
    if thrBin < 0 { thrBin = 0 }
    if thrBin >= binCount { thrBin = binCount - 1 }
    
    // 7) Above fraction: mass right of the threshold bin
    let binWidth = 1.0 / Double(binCount)
    let binLower = Double(thrBin) * binWidth
    let binUpper = binLower + binWidth
    let massThrBin = Double(max(0, buf[thrBin*4 + 0])) // R channel count for thrBin
    let fracInThrBinAbove = max(0.0, min(1.0, (binUpper - thrNorm) / binWidth))
    let aboveStrict = totalHist - cdf[thrBin]                // mass strictly to the right
    let aboveIncl   = aboveStrict + massThrBin * fracInThrBinAbove
    let frac        = aboveIncl / totalHist
    
    // 8) Convert to pixel counts using metadata width/height (not histogram sum)
    let totalPx = pixelCount(of: ciImage)
    let clippedPx = frac * totalPx

    // DEBUG
    dbg(String(format:
      "    [fractionAboveHeadroomThreshold-debug] absMax=%.6f thr=%.6f thrNorm=%.6f binCount=%d thrBin=%d aboveIncl=%.0f total=%.0f frac=%.6f\n",
      absMax, Double(thresholdHeadroom), thrNorm, binCount, thrBin, aboveIncl, totalHist, frac
    ))

    return (frac, clippedPx, totalPx)
}

/// Get pixel count using metadata width/height when available; fallback to extent.
func pixelCount(of img: CIImage) -> Double {
    let props = img.properties
    if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
       let h = props[kCGImagePropertyPixelHeight as String] as? Int,
       w > 0, h > 0 {
        return Double(w * h)
    }
    let w = max(0, Int(img.extent.width.rounded()))
    let h = max(0, Int(img.extent.height.rounded()))
    return Double(w * h)
}

/// Build a BW clip mask (white = clipped) at full resolution using only standard CI filters.
func buildClipMaskImage_NoKernel(hdr: CIImage, thresholdHeadroom: Float) -> CIImage? {
    // 1) Linear luminance in R
    var yImg = linearLuma(hdr)
    // 2) Subtract threshold on R
    let sub = CIFilter.colorMatrix(); sub.inputImage = yImg
    sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    sub.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    sub.biasVector = CIVector(x: CGFloat(-thresholdHeadroom), y: 0, z: 0, w: 0)
    yImg = sub.outputImage!

    // 3) Clamp negatives to 0 (keep positives)
    let clampPos = CIFilter.colorClamp(); clampPos.inputImage = yImg
    clampPos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clampPos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
    yImg = clampPos.outputImage!

    // 4) Hard threshold via huge gain + clamp to [0,1]
    let gain: CGFloat = 1_000_000
    let amp = CIFilter.colorMatrix(); amp.inputImage = yImg
    amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
    amp.gVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.bVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.aVector = CIVector(x: 0,    y: 0, z: 0, w: 1)
    yImg = amp.outputImage!

    let clamp01 = CIFilter.colorClamp(); clamp01.inputImage = yImg
    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
    let binaryR = clamp01.outputImage!

    // 5) Copy R → RGB (mask luminance in all channels)
    let toRGB = CIFilter.colorMatrix(); toRGB.inputImage = binaryR
    toRGB.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return toRGB.outputImage
}

/// Build a BW clip mask (white = clipped) at full resolution, and write a PNG next to the HEIC.
/// Uses only standard Core Image filters (no deprecated kernel API).
@discardableResult
func writeClipMaskPNG_NoKernel(hdr: CIImage,
                               thresholdHeadroom: Float,
                               ctx: CIContext,
                               outURL: URL) -> URL? {
    // 1) Luminanza lineare in R (G/B=0, A=1) – usa la tua linearLuma(_:)
    var yImg = linearLuma(hdr)

    // 2) Sottrai la soglia sul canale R (bias.x = -threshold)
    let sub = CIFilter.colorMatrix()
    sub.inputImage = yImg
    sub.rVector   = CIVector(x: 1, y: 0, z: 0, w: 0)  // passa R invariato (prima della sottrazione)
    sub.gVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.bVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
    sub.biasVector = CIVector(x: CGFloat(-thresholdHeadroom), y: 0, z: 0, w: 0)
    yImg = sub.outputImage!

    // 3) Clippa i negativi a 0 (così restano positivi solo i pixel > soglia)
    let clampPos = CIFilter.colorClamp()
    clampPos.inputImage = yImg
    clampPos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)          // min 0
    clampPos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)         // lascia liberi i positivi su R
    yImg = clampPos.outputImage!

    // 4) Amplifica enormemente i positivi, poi richiudi in [0,1] → step “duro”
    let gain: CGFloat = 1_000_000
    let amp = CIFilter.colorMatrix()
    amp.inputImage = yImg
    amp.rVector   = CIVector(x: gain, y: 0,    z: 0,    w: 0)  // moltiplica R
    amp.gVector   = CIVector(x: 0,    y: 0,    z: 0,    w: 0)
    amp.bVector   = CIVector(x: 0,    y: 0,    z: 0,    w: 0)
    amp.aVector   = CIVector(x: 0,    y: 0,    z: 0,    w: 1)
    amp.biasVector = CIVector(x: 0,   y: 0,    z: 0,    w: 0)
    yImg = amp.outputImage!

    let clamp01 = CIFilter.colorClamp()
    clamp01.inputImage = yImg
    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
    yImg = clamp01.outputImage!

    // 5) Copia R → RGB (per ottenere una PNG grigia “piena” 0/255)
    let toRGB = CIFilter.colorMatrix()
    toRGB.inputImage = yImg
    // out.R = in.R; out.G = in.R; out.B = in.R; out.A = 1
    toRGB.rVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.gVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.bVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    toRGB.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
    toRGB.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    let maskRGB = toRGB.outputImage!

    // 6) Scrivi PNG 8-bit (sRGB va benissimo per una maschera binaria)
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let pngURL = outURL.deletingPathExtension()
                       .appendingPathExtension("png")
                       .deletingLastPathComponent()
                       .appendingPathComponent(outURL.deletingPathExtension().lastPathComponent + "_clipmask.png")
    do {
        try ctx.writePNGRepresentation(of: maskRGB,
                                      to: pngURL,
                                      format: .RGBA8,
                                      colorSpace: sRGB,
                                      options: [:])
        fputs("  • Wrote clip mask: \(pngURL.path)\n", stderr)
        return pngURL
    } catch {
        fputs("  ! Failed to write clip mask PNG: \(error)\n", stderr)
        return nil
    }
}
/// Write an SDR PNG where clipped pixels are replaced with a solid color (mask white → color).
@discardableResult
func writeMaskedSDRImage(sdrBase: CIImage,
                         mask: CIImage,
                         solid: CIColor,
                         ctx: CIContext,
                         outURL: URL) -> URL? {
    // --- constant color (infinite extent) ---
    guard let gen = CIFilter(name: "CIConstantColorGenerator") else {
        fputs("  ! CIConstantColorGenerator not available\n", stderr)
        return nil
    }
    gen.setValue(solid, forKey: kCIInputColorKey)
    guard let colorInfinite = gen.outputImage else {
        fputs("  ! constantColorGenerator failed\n", stderr)
        return nil
    }
    // IMPORTANT: crop infinite extent to the SDR extent
    let colorImg = colorInfinite.cropped(to: sdrBase.extent)

    // --- blend with mask: white → color, black → background (SDR base) ---
    guard let blend = CIFilter(name: "CIBlendWithMask") else {
        fputs("  ! CIBlendWithMask not available\n", stderr)
        return nil
    }
    blend.setValue(colorImg, forKey: kCIInputImageKey)
    blend.setValue(sdrBase,   forKey: kCIInputBackgroundImageKey)
    blend.setValue(mask,      forKey: kCIInputMaskImageKey)
    guard let overlaid = blend.outputImage else {
        fputs("  ! blendWithMask failed\n", stderr)
        return nil
    }

    // --- write PNG 8-bit sRGB next to the HEIC, with suffix _clippedOverlay.png ---
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let pngURL = outURL.deletingPathExtension()
                       .appendingPathExtension("png")
                       .deletingLastPathComponent()
                       .appendingPathComponent(outURL.deletingPathExtension().lastPathComponent + "_clippedOverlay.png")
    do {
        try ctx.writePNGRepresentation(of: overlaid,
                                      to: pngURL,
                                      format: .RGBA8,
                                      colorSpace: sRGB,
                                      options: [:])
        fputs("  • Wrote masked SDR overlay: \(pngURL.path)\n", stderr)
        return pngURL
    } catch {
        fputs("  ! Failed to write masked SDR overlay: \(error)\n", stderr)
        return nil
    }
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
        let outURL = outputDir
            .appendingPathComponent(basename + options.outputSuffix)
            .appendingPathExtension("heic")
        fputs("Processing \(basename)…\n", stderr)

        // Load HDR (with headroom preserved)
        guard let hdr = CIImage(contentsOf: hdrURL, options: [.expandToHDR: true]) else {
            fputs("  ! Cannot read HDR: \(hdrURL.path)\n", stderr); return
        }
        // Enforce HDR color space = Display P3 PQ
        guard let hdrCS = csName(hdr.colorSpace), hdrCS == hdrRequired else {
            fputs("  ! HDR colorspace not Display P3 PQ (got: \(csName(hdr.colorSpace) ?? "nil"))\n", stderr); return
        }

        // --- measurement of headroom ---
        // will use this both for tonemapping, if required,
        // as well as for calculation of makerApple (33,48)
        let picHeadroom: Float
        let headroomRatio: Float
        let tonemapRatioDefault: Float = 0.2

        if options.usePercentile {
            // Percentile method → robust peak, then use it straight as source headroom; no blend curve.
            guard let h = percentileHeadroom(from: hdr, context: ctxLinearP3, linearCS: linearP3,
                                             bins: kCIHistogramMaxBins, percentile: options.peakPercentile) else {
                fputs("  ! Cannot compute percentile headroom\n", stderr); return
            }
            picHeadroom = h
            headroomRatio = picHeadroom        // source headroom
            fputs(String(format: "  • Percentile %.3f -> headroom %.3fx\n", options.peakPercentile, picHeadroom), stderr)
        } else {
            // Legacy method → pure max + blend with tonemapRatio=0.2
            guard let h = maxLuminanceHDR(from: hdr, context: ctxLinearP3, linearCS: linearP3) else {
                fputs("  ! Cannot compute luminance peak\n", stderr); return
            }
            picHeadroom = h
            headroomRatio = max(1.0, 1.0 + picHeadroom - powf(picHeadroom, tonemapRatioDefault))
            fputs(String(format: "  • Max-peak=%.3fx -> headroomRatio=%.3f (tonemapRatio=%.1f)\n",
                         picHeadroom, headroomRatio, tonemapRatioDefault), stderr)
        }
        
        if options.tonemapDryRun {
            // Report clipping relative to the selected threshold (headroomRatio)
            if let clip = fractionAboveHeadroomThreshold(from: hdr,
                                                         context: ctxLinearP3,
                                                         linearCS: linearP3,
                                                         thresholdHeadroom: headroomRatio,
                                                         bins: 2048) {
                fputs(String(format: "  [dryrun] Pixels above headroom (%.3fx): %.3f%% (≈%.0f / %.0f)\n",
                             headroomRatio, clip.fraction * 100.0, clip.clippedPixels, clip.totalPixels), stderr)
            } else {
                fputs(String(format: "  [dryrun] Pixels above headroom (%.3fx): <n/a> (≈<n/a> / <n/a>)\n",
                             headroomRatio), stderr)
            }
            // Skip SDR generation / gain-map / export
            return
        }

        // Choose pipeline: use provided SDR if present, otherwise tonemap
        let hasSDR = FileManager.default.fileExists(atPath: sdrURL.path)
        let sdrBase: CIImage
        if hasSDR {
            fputs("  Found SDR counterpart, using it as base image\n", stderr)
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
            fputs("  SDR image not found, producing one by tonemapping\n", stderr)
            // --- Branch B: Tonemap SDR from HDR ---
            if options.emitClipMask {
                _ = writeClipMaskPNG_NoKernel(hdr: hdr,
                                              thresholdHeadroom: headroomRatio,
                                              ctx: encodeCtx,
                                              outURL: outURL)
            }
            guard let sdr = tonemapSDR(from: hdr, headroomRatio: headroomRatio) else {
                fputs("  ! Tonemapping failed\n", stderr); return
            }

            // Print clipped-pixel percentage ONLY when SDR is generated (tonemapping case)
            if let clip = fractionAboveHeadroomThreshold(from: hdr,
                                                         context: ctxLinearP3,
                                                         linearCS: linearP3,
                                                         thresholdHeadroom: headroomRatio,
                                                         bins: kCIHistogramMaxBins) {
                fputs(String(format: "  • Pixels above headroom (%.3fx): %.3f%% (≈%.0f px)\n",
                             headroomRatio, clip.fraction * 100.0, clip.totalPixels * clip.fraction), stderr)
            } else {
                fputs("  • Clip fraction: <n/a>\n", stderr)
            }

            sdrBase = sdr
            
            // Write SDR image with clipped pixels highlighted in a pre-defined color
            if options.emitMaskedImage && !options.tonemapDryRun {
                // Build BW mask once
                if let clipMask = buildClipMaskImage_NoKernel(hdr: hdr, thresholdHeadroom: headroomRatio) {
                    let color = parseColor(options.maskedColor)
                    _ = writeMaskedSDRImage(sdrBase: sdrBase,
                                            mask: clipMask,
                                            solid: color,
                                            ctx: encodeCtx,
                                            outURL: outURL)
                } else {
                    fputs("  ! Failed to build clip mask (overlay skipped)\n", stderr)
                }
            }

        }

        // Compute makerApple (33,48) from measured linear headroom
        let maker = makerAppleFromHeadroom(picHeadroom)
        guard let chosen = maker.default else {
            fputs("  ! No valid makerApple pair for headroom=\(picHeadroom)\n", stderr); return
        }

        // Use effective headroom (metadata) for ex-post validation
        let headroomUsedForMetadata = powf(2.0, max(maker.stops, 0.0))
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
        let tmpOptions: [CIImageRepresentationOption : Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0, // high-quality SDR in temp pair
            CIImageRepresentationOption.hdrImage: hdr,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
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
