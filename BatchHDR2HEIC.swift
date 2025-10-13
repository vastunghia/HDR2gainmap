import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------
let input_hdr_dir  = URL(fileURLWithPath: "./input_HDR/", isDirectory: true)
let input_sdr_dir  = URL(fileURLWithPath: "./input_SDR/", isDirectory: true)
let output_dir     = URL(fileURLWithPath: "./output_HDR_with_gainmap/", isDirectory: true)
let output_clipped_mask_dir    = URL(fileURLWithPath: "./output_clipped_mask/", isDirectory: true)
let output_clipped_overlay_dir = URL(fileURLWithPath: "./output_clipped_overlay/", isDirectory: true)

// Ensure folders exist (HDR input must exist; create output if missing)
var is_dir: ObjCBool = false
guard FileManager.default.fileExists(atPath: input_hdr_dir.path, isDirectory: &is_dir), is_dir.boolValue else {
    fputs("Missing folder: \(input_hdr_dir.path)\n", stderr); exit(73)
}
if !FileManager.default.fileExists(atPath: output_dir.path, isDirectory: &is_dir) {
    do { try FileManager.default.createDirectory(at: output_dir, withIntermediateDirectories: true) }
    catch { fputs("Cannot create output dir: \(error)\n", stderr); exit(73) }
}

// number of bins when building histograms (max allowed by CIAreaHistogram is 2048)
let CI_HISTOGRAM_MAX_BINS = 2048

// -----------------------------------------------------------------------------
// CLI parsing with strict validation
// -----------------------------------------------------------------------------

struct Options {
    var output_suffix: String = ""
    var use_percentile: Bool = false
    var peak_percentile: Float = 99.9
    var peak_max: Bool = true
    var tonemap_ratio: Float = 0.2
    var heic_compression_quality: Float = 0.97
    var tonemap_dryrun: Bool = false
    var emit_clip_mask: Bool = false
    var emit_masked_image: Bool = false
    var masked_color: String = "magenta"
    var debug: Bool = false
}

@discardableResult
func print_usage(_ prog: String) -> Int32 {
    fputs("""
    Usage:
      \(prog) [--suffix <text>] [--peak_percentile [value]] [--peak_max]
             [--tonemap_ratio <0..1>] [--heic_compression_quality <0..1>]
             [--tonemap_dryrun] [--emit_clip_mask] [--emit_masked_image [color]] [--debug]

    Options:
      --suffix <text>                 Suffix appended to output filename (e.g. "_sdrtm")
      --peak_percentile [value]       Use percentile-based peak (default 99.9 if value omitted)
      --peak_max                      Use absolute max + blend (tonemap_ratio applied)  [DEFAULT]
      --tonemap_ratio <0..1>          Blend curve for peak_max (default 0.2)
      --heic_compression_quality <v>  HEIC lossy quality in [0,1] (default 0.97)
      --tonemap_dryrun                Only compute headroom + clipped fraction; no HEIC output
      --emit_clip_mask                Also write a black/white mask of clipped pixels
                                      (ignored if an SDR file already exists)
      --emit_masked_image [col]       Also write SDR with clipped pixels painted (name or #RRGGBB; default: magenta)
                                      (ignored if an SDR file already exists)
      --debug                         Print verbose debug messages
      --help                          Show this message

    """, stderr)
    return 64
}

func parse_options(_ argv: [String]) -> Options {
    var opts = Options()
    let allowed = Set([
        "--suffix","--peak_percentile","--peak_max","--tonemap_ratio",
        "--heic_compression_quality",
        "--tonemap_dryrun","--emit_clip_mask","--emit_masked_image",
        "--debug","--help"
    ])
    var i = 1
    let n = argv.count
    let prog = (argv.first ?? "prog")

    while i < n {
        let tok = argv[i]
        guard tok.hasPrefix("-") else { fputs("Unknown positional argument: \(tok)\n", stderr); exit(print_usage(prog)) }
        if tok == "--help" { exit(print_usage(prog)) }
        guard allowed.contains(tok) else { fputs("Unknown option: \(tok)\n", stderr); exit(print_usage(prog)) }

        switch tok {
            
        case "--suffix":
            guard i+1 < n, !argv[i+1].hasPrefix("-") else { fputs("Option --suffix requires a value.\n", stderr); exit(print_usage(prog)) }
            var suffix = argv[i+1]
            if !suffix.isEmpty && !suffix.hasPrefix("_") && !suffix.hasPrefix("-") { suffix = "_" + suffix }
            opts.output_suffix = suffix
            i += 2

        case "--peak_percentile":
            if i+1 < n, !argv[i+1].hasPrefix("-") {
                guard let p = Float(argv[i+1]), p > 0, p <= 100 else {
                    fputs("Invalid value for --peak_percentile: \(argv[i+1])\n", stderr); exit(print_usage(prog))
                }
                opts.peak_percentile = p
                opts.use_percentile = true
                opts.peak_max = false
                i += 2
            } else {
                // no value provided: enable percentile with default 99.9
                opts.use_percentile = true
                opts.peak_max = false
                i += 1
            }

        case "--peak_max":
            opts.peak_max = true
            opts.use_percentile = false
            i += 1

        case "--tonemap_ratio":
            guard i+1 < n, !argv[i+1].hasPrefix("-"),
                  let v = Float(argv[i+1]), v >= 0.0, v <= 1.0 else {
                fputs("Option --tonemap_ratio requires a numeric value in [0,1].\n", stderr)
                exit(print_usage(prog))
            }
            opts.tonemap_ratio = v
            i += 2

        case "--tonemap_dryrun":
            opts.tonemap_dryrun = true
            i += 1
            
        case "--heic_compression_quality":
            guard i+1 < n, !argv[i+1].hasPrefix("-"),
                  let v = Float(argv[i+1]), v >= 0.0, v <= 1.0 else {
                fputs("Option --heic_compression_quality requires a numeric value in [0,1].\n", stderr)
                exit(print_usage(prog))
            }
            opts.heic_compression_quality = v
            i += 2

        case "--emit_clip_mask":
            opts.emit_clip_mask = true
            i += 1

        case "--emit_masked_image":
            opts.emit_masked_image = true
            if i+1 < n, !argv[i+1].hasPrefix("-") {
                opts.masked_color = argv[i+1]; i += 2
            } else { i += 1 }

        case "--debug":
            opts.debug = true
            i += 1

        default:
            fputs("Unhandled option: \(tok)\n", stderr); exit(print_usage(prog))
        }
    }
    return opts
}


let options = parse_options(CommandLine.arguments)

@inline(__always)
func dbg_log(_ message: @autoclosure () -> String) {
    if options.debug { fputs(message(), stderr) }
}

if options.use_percentile && options.debug {
    fputs("  (debug) Note: --tonemap_ratio is ignored with --peak_percentile.\n", stderr)
}
// Create optional output folders only if requested by CLI flags
if options.emit_clip_mask {
    var is_dir2: ObjCBool = false
    if !FileManager.default.fileExists(atPath: output_clipped_mask_dir.path, isDirectory: &is_dir2) {
        do { try FileManager.default.createDirectory(at: output_clipped_mask_dir, withIntermediateDirectories: true) }
        catch { fputs("Cannot create output_clipped_mask dir: \(error)\n", stderr); exit(73) }
    }
}
if options.emit_masked_image {
    var is_dir3: ObjCBool = false
    if !FileManager.default.fileExists(atPath: output_clipped_overlay_dir.path, isDirectory: &is_dir3) {
        do { try FileManager.default.createDirectory(at: output_clipped_overlay_dir, withIntermediateDirectories: true) }
        catch { fputs("Cannot create output_clipped_overlay dir: \(error)\n", stderr); exit(73) }
    }
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

/// Parse a color string into CIColor. Accepts simple names or "#RRGGBB".
func parse_color(_ s: String) -> CIColor {
    let lower = s.lowercased()
    switch lower {
    case "red":     return CIColor(red: 1, green: 0, blue: 0)
    case "magenta": return CIColor(red: 1, green: 0, blue: 1)
    case "violet":  return CIColor(red: 0.56, green: 0, blue: 1)
    default:
        if lower.hasPrefix("#"), lower.count == 7 {
            let r_str = String(lower.dropFirst().prefix(2))
            let g_str = String(lower.dropFirst(3).prefix(2))
            let b_str = String(lower.dropFirst(5).prefix(2))
            let r = CGFloat(Int(r_str, radix: 16) ?? 255) / 255.0
            let g = CGFloat(Int(g_str, radix: 16) ?? 0)   / 255.0
            let b = CGFloat(Int(b_str, radix: 16) ?? 255) / 255.0
            return CIColor(red: r, green: g, blue: b)
        }
        // Fallback: magenta
        return CIColor(red: 1, green: 0, blue: 1)
    }
}

/// Return the canonical CGColorSpace name as String (or nil if untagged)
func cs_name(_ cs: CGColorSpace?) -> String? {
    guard let cs = cs, let name = cs.name else { return nil }
    return name as String
}

/// Put linear luminance (Y) in R; zero G/B; A=1.
func linear_luma(_ src: CIImage) -> CIImage {
    let m = CIFilter.colorMatrix()
    m.inputImage = src
    m.rVector   = CIVector(x: 0.2126, y: 0,      z: 0,      w: 0)
    m.gVector   = CIVector(x: 0.7152, y: 0,      z: 0,      w: 0)
    m.bVector   = CIVector(x: 0.0722, y: 0,      z: 0,      w: 0)
    m.aVector   = CIVector(x: 0,      y: 0,      z: 0,      w: 1)
    m.biasVector = CIVector(x: 0,     y: 0,      z: 0,      w: 0)
    return m.outputImage!
}

/// Measure a linear-light luminance peak proxy in extended linear P3 using CIAreaMaximum.
func max_luminance_hdr(from ci_image: CIImage,
                       context: CIContext,
                       linear_cs: CGColorSpace) -> Float? {
    let y_img = linear_luma(ci_image)
    let filter = CIFilter.areaMaximum()
    filter.inputImage = y_img
    filter.extent = y_img.extent
    guard let out = filter.outputImage else { return nil }

    var px = [Float](repeating: 0, count: 4)
    context.render(out,
                   toBitmap: &px,
                   rowBytes: MemoryLayout<Float>.size * 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf,
                   colorSpace: linear_cs)
    let y_peak = max(0, px[0])
    return y_peak
}

/// Linear-luminance percentile (robust peak) in extended linear P3.
func percentile_headroom(from ci_image: CIImage,
                         context: CIContext,
                         linear_cs: CGColorSpace,
                         bins: Int = 1024,
                         percentile: Float = 99.9) -> Float? {
    let bin_count = min(max(bins, 1), 2048)

    guard let abs_max = max_luminance_hdr(from: ci_image, context: context, linear_cs: linear_cs),
          abs_max > 0 else { return 1.0 }

    var y_img = linear_luma(ci_image)

    // Normalize Y by abs_max → [0,1]
    let norm = CIFilter.colorMatrix()
    norm.inputImage = y_img
    let s = CGFloat(1.0) / CGFloat(abs_max)
    norm.rVector   = CIVector(x: s, y: .zero, z: .zero, w: .zero)
    norm.gVector   = CIVector(x: .zero, y: 1.0,  z: .zero, w: .zero)
    norm.bVector   = CIVector(x: .zero, y: .zero, z: 1.0,  w: .zero)
    norm.aVector   = CIVector(x: .zero, y: .zero, z: .zero, w: 1.0)
    norm.biasVector = CIVector(x: .zero, y: .zero, z: .zero, w: .zero)
    y_img = norm.outputImage!

    let hist = CIFilter.areaHistogram()
    hist.inputImage = y_img
    hist.extent = y_img.extent
    hist.count = bin_count
    hist.scale = 1.0

    guard let hist_image = hist.outputImage else { return nil }

    var buf = [Float](repeating: 0, count: bin_count * 4)
    context.render(hist_image,
                   toBitmap: &buf,
                   rowBytes: MemoryLayout<Float>.size * 4 * bin_count,
                   bounds: CGRect(x: 0, y: 0, width: bin_count, height: 1),
                   format: .RGBAf,
                   colorSpace: linear_cs)

    var cdf = [Double](repeating: 0, count: bin_count)
    var total: Double = 0
    for i in 0..<bin_count {
        let c = Double(max(0, buf[i*4 + 0]))
        total += c
        cdf[i] = total
    }
    guard total > 0 else { return 1.0 }

    var k = 0
    let target = Double(percentile) / 100.0 * total
    while k < bin_count && cdf[k] < target { k += 1 }
    if k >= bin_count { k = bin_count - 1 }

    let v_norm = (Double(k) + 0.5) / Double(bin_count)
    let y_percentile = Float(v_norm) * abs_max

    let reached = cdf[k] / total
    dbg_log(String(format:
      "    [percentile_headroom-debug] bins=%d absMax=%.6f target=%.1f%% k=%d  vNorm=%.6f  CDF=%.4f  yPercentile=%.6f headroom=%.6f\n",
      bin_count, abs_max, Double(percentile), k, v_norm, reached, Double(y_percentile), Double(max(y_percentile, 1.0))
    ))

    return max(y_percentile, 1.0)
}

/// Fraction of pixels with linear luminance above a threshold (headroom).
func fraction_above_headroom_threshold(from ci_image: CIImage,
                                       context: CIContext,
                                       linear_cs: CGColorSpace,
                                       threshold_headroom: Float,
                                       bins: Int = 1024)
-> (fraction: Double, clipped_pixels: Double, total_pixels: Double)? {

    let bin_count = min(max(bins, 1), 2048)

    guard let abs_max = max_luminance_hdr(from: ci_image, context: context, linear_cs: linear_cs),
          abs_max > 0 else { return nil }

    var y_img = linear_luma(ci_image)

    let norm = CIFilter.colorMatrix()
    norm.inputImage = y_img
    let s = CGFloat(1.0) / CGFloat(abs_max)
    norm.rVector   = CIVector(x: s, y: .zero, z: .zero, w: .zero)
    norm.gVector   = CIVector(x: .zero, y: 1.0,  z: .zero, w: .zero)
    norm.bVector   = CIVector(x: .zero, y: .zero, z: 1.0,  w: .zero)
    norm.aVector   = CIVector(x: .zero, y: .zero, z: .zero, w: 1.0)
    norm.biasVector = CIVector(x: .zero, y: .zero, z: .zero, w: .zero)
    y_img = norm.outputImage!

    let hist = CIFilter.areaHistogram()
    hist.inputImage = y_img
    hist.extent = y_img.extent
    hist.count = bin_count
    hist.scale = 1.0

    guard let hist_image = hist.outputImage else { return nil }

    var buf = [Float](repeating: 0, count: bin_count * 4)
    context.render(hist_image,
                   toBitmap: &buf,
                   rowBytes: MemoryLayout<Float>.size * 4 * bin_count,
                   bounds: CGRect(x: 0, y: 0, width: bin_count, height: 1),
                   format: .RGBAf,
                   colorSpace: linear_cs)

    var cdf = [Double](repeating: 0, count: bin_count)
    var total_hist: Double = 0
    for i in 0..<bin_count {
        let c = Double(max(0, buf[i*4 + 0]))
        total_hist += c
        cdf[i] = total_hist
    }
    guard total_hist > 0 else { return (0.0, 0.0, 0.0) }

    let thr_norm = min(max(Double(threshold_headroom / abs_max), 0.0), 1.0)
    var thr_bin = Int(floor(thr_norm * Double(bin_count)))
    if thr_bin < 0 { thr_bin = 0 }
    if thr_bin >= bin_count { thr_bin = bin_count - 1 }

    let bin_width = 1.0 / Double(bin_count)
    let bin_lower = Double(thr_bin) * bin_width
    let bin_upper = bin_lower + bin_width
    let mass_thr_bin = Double(max(0, buf[thr_bin*4 + 0]))
    let frac_in_thr_bin_above = max(0.0, min(1.0, (bin_upper - thr_norm) / bin_width))
    let above_strict = total_hist - cdf[thr_bin]
    let above_incl   = above_strict + mass_thr_bin * frac_in_thr_bin_above
    let frac         = above_incl / total_hist

    let total_px = pixel_count(of: ci_image)
    let clipped_px = frac * total_px

    dbg_log(String(format:
      "    [fraction_above_headroom_threshold-debug] absMax=%.6f thr=%.6f thrNorm=%.6f binCount=%d thrBin=%d aboveIncl=%.0f total=%.0f frac=%.6f\n",
      abs_max, Double(threshold_headroom), thr_norm, bin_count, thr_bin, above_incl, total_hist, frac
    ))

    return (frac, clipped_px, total_px)
}

/// Get pixel count using metadata width/height when available; fallback to extent.
func pixel_count(of img: CIImage) -> Double {
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

/// Build a BW clip mask (white = clipped) using only standard CI filters.
func build_clip_mask_image_no_kernel(hdr: CIImage, threshold_headroom: Float) -> CIImage? {
    var y_img = linear_luma(hdr)

    let sub = CIFilter.colorMatrix(); sub.inputImage = y_img
    sub.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    sub.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    sub.biasVector = CIVector(x: CGFloat(-threshold_headroom), y: 0, z: 0, w: 0)
    y_img = sub.outputImage!

    let clamp_pos = CIFilter.colorClamp(); clamp_pos.inputImage = y_img
    clamp_pos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp_pos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
    y_img = clamp_pos.outputImage!

    let gain: CGFloat = 1_000_000
    let amp = CIFilter.colorMatrix(); amp.inputImage = y_img
    amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
    amp.gVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.bVector = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.aVector = CIVector(x: 0,    y: 0, z: 0, w: 1)
    y_img = amp.outputImage!

    let clamp01 = CIFilter.colorClamp(); clamp01.inputImage = y_img
    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
    let binary_r = clamp01.outputImage!

    let to_rgb = CIFilter.colorMatrix(); to_rgb.inputImage = binary_r
    to_rgb.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return to_rgb.outputImage
}

/// Write a BW clip mask (white=clipped) next to the HEIC.
@discardableResult
func write_clip_mask_no_kernel(hdr: CIImage,
                                   threshold_headroom: Float,
                                   ctx: CIContext,
                                   out_url: URL) -> URL? {
    // build mask (identico a prima)
    var y_img = linear_luma(hdr)

    let sub = CIFilter.colorMatrix()
    sub.inputImage = y_img
    sub.rVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    sub.gVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.bVector   = CIVector(x: 0, y: 0, z: 0, w: 0)
    sub.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
    sub.biasVector = CIVector(x: CGFloat(-threshold_headroom), y: 0, z: 0, w: 0)
    y_img = sub.outputImage!

    let clamp_pos = CIFilter.colorClamp()
    clamp_pos.inputImage = y_img
    clamp_pos.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp_pos.maxComponents = CIVector(x: 1e9, y: 0, z: 0, w: 1)
    y_img = clamp_pos.outputImage!

    let gain: CGFloat = 1_000_000
    let amp = CIFilter.colorMatrix()
    amp.inputImage = y_img
    amp.rVector   = CIVector(x: gain, y: 0, z: 0, w: 0)
    amp.gVector   = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.bVector   = CIVector(x: 0,    y: 0, z: 0, w: 0)
    amp.aVector   = CIVector(x: 0,    y: 0, z: 0, w: 1)
    amp.biasVector = CIVector(x: 0,   y: 0, z: 0, w: 0)
    y_img = amp.outputImage!

    let clamp01 = CIFilter.colorClamp()
    clamp01.inputImage = y_img
    clamp01.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
    clamp01.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
    y_img = clamp01.outputImage!

    let to_rgb = CIFilter.colorMatrix()
    to_rgb.inputImage = y_img
    to_rgb.rVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.gVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.bVector   = CIVector(x: 1, y: 0, z: 0, w: 0)
    to_rgb.aVector   = CIVector(x: 0, y: 0, z: 0, w: 1)
    to_rgb.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    let mask_rgb = to_rgb.outputImage!

    let base = out_url.deletingPathExtension().lastPathComponent
    let heic_url = output_clipped_mask_dir.appendingPathComponent(base + "_clipmask.heic")

    let heic_opts: [CIImageRepresentationOption: Any] = [
        kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.heic_compression_quality
    ]

    do {
        try ctx.writeHEIFRepresentation(of: mask_rgb,
                                        to: heic_url,
                                        format: .RGB10,
                                        colorSpace: p3_cs,
                                        options: heic_opts)
        fputs("  • Wrote clip mask HEIC: \(heic_url.path)\n", stderr)
        return heic_url
    } catch {
        fputs("  ! Failed to write clip mask HEIC: \(error)\n", stderr)
        return nil
    }
}

/// Write an SDR image where clipped pixels are replaced with a solid color.
@discardableResult
func write_masked_sdr_image(sdr_base: CIImage,
                            mask: CIImage,
                            solid: CIColor,
                            ctx: CIContext,
                            out_url: URL) -> URL? {
    // costruzione overlay (identica, cambia solo il writer)
    guard let gen = CIFilter(name: "CIConstantColorGenerator") else {
        fputs("  ! CIConstantColorGenerator not available\n", stderr)
        return nil
    }
    gen.setValue(solid, forKey: kCIInputColorKey)
    guard let color_infinite = gen.outputImage else {
        fputs("  ! constantColorGenerator failed\n", stderr)
        return nil
    }
    let color_img = color_infinite.cropped(to: sdr_base.extent)

    guard let blend = CIFilter(name: "CIBlendWithMask") else {
        fputs("  ! CIBlendWithMask not available\n", stderr)
        return nil
    }
    blend.setValue(color_img, forKey: kCIInputImageKey)
    blend.setValue(sdr_base,  forKey: kCIInputBackgroundImageKey)
    blend.setValue(mask,      forKey: kCIInputMaskImageKey)
    guard let overlaid = blend.outputImage else {
        fputs("  ! blendWithMask failed\n", stderr)
        return nil
    }

    let base = out_url.deletingPathExtension().lastPathComponent
    let heic_url = output_clipped_overlay_dir.appendingPathComponent(base + "_clippedOverlay.heic")

    let heic_opts: [CIImageRepresentationOption: Any] = [
        kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.heic_compression_quality
    ]

    do {
        try ctx.writeHEIFRepresentation(of: overlaid,
                                        to: heic_url,
                                        format: .RGB10,
                                        colorSpace: p3_cs,
                                        options: heic_opts)
        fputs("  • Wrote masked SDR overlay HEIC: \(heic_url.path)\n", stderr)
        return heic_url
    } catch {
        fputs("  ! Failed to write masked SDR overlay HEIC: \(error)\n", stderr)
        return nil
    }
}

// --- Apple metadata mapping (inverse + forward) ---

struct MakerAppleResult {
    struct Candidate {
        let maker33: Float
        let maker48: Float
        let stops: Float
        let branch: String
    }
    let stops: Float
    let candidates: [Candidate]
    let `default`: Candidate?
}

func maker_apple_from_headroom(_ headroom_linear: Float) -> MakerAppleResult {
    let clamped = min(max(headroom_linear, 1.0), 8.0) // up to 3 stops
    let stops = log2f(clamped)
    var cs: [MakerAppleResult.Candidate] = []

    do { let m48 = (1.8 - stops)/20.0;  if m48 >= 0,  m48 <= 0.01 { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & <=0.01")) } }
    do { let m48 = (1.601 - stops)/0.101; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 0.0, maker48: m48, stops: stops, branch: "<1 & >0.01")) } }
    do { let m48 = (3.0 - stops)/70.0;   if m48 >= 0,  m48 <= 0.01 { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & <=0.01")) } }
    do { let m48 = (2.303 - stops)/0.303; if m48 > 0.01, m48.isFinite { cs.append(.init(maker33: 1.0, maker48: m48, stops: stops, branch: ">=1 & >0.01")) } }

    let preferred = cs.first { $0.maker33 >= 1.0 && $0.maker48 <= 0.01 }
                 ?? cs.first { $0.maker33 >= 1.0 }
                 ?? cs.first
    return .init(stops: stops, candidates: cs, default: preferred)
}

func stops_from_maker_apple(maker33: Float, maker48: Float) -> (stops: Float, branch: String)? {
    if maker33 < 1.0 {
        if maker48 <= 0.01 { return (-20.0*maker48 + 1.8, "<1 & <=0.01") }
        else               { return (-0.101*maker48 + 1.601, "<1 & >0.01") }
    } else {
        if maker48 <= 0.01 { return (-70.0*maker48 + 3.0, ">=1 & <=0.01") }
        else               { return (-0.303*maker48 + 2.303, ">=1 & >0.01") }
    }
}

struct MakerValidationDiffs {
    let target_stops: Float
    let forward_stops: Float
    let abs_stops_diff: Float
    let target_headroom: Float
    let forward_headroom: Float
    let rel_headroom_diff: Float
    let branch: String
}

func validate_maker_apple(headroom_linear: Float,
                          maker33: Float,
                          maker48: Float,
                          tol_stops_abs: Float = 0.01,
                          tol_headroom_rel: Float = 0.02) -> (ok: Bool, diffs: MakerValidationDiffs?) {
    let target_headroom = max(headroom_linear, 1.0)
    let target_stops = log2f(target_headroom)
    guard let (forward_stops, branch) = stops_from_maker_apple(maker33: maker33, maker48: maker48) else {
        return (false, nil)
    }
    let forward_headroom = powf(2.0, max(forward_stops, 0.0))
    let abs_stops_diff = abs(forward_stops - target_stops)
    let rel_headroom_diff = abs(forward_headroom - target_headroom) / target_headroom
    let ok = (abs_stops_diff <= tol_stops_abs) && (rel_headroom_diff <= tol_headroom_rel)
    return (ok, .init(target_stops: target_stops, forward_stops: forward_stops, abs_stops_diff: abs_stops_diff,
                      target_headroom: target_headroom, forward_headroom: forward_headroom,
                      rel_headroom_diff: rel_headroom_diff, branch: branch))
}

// Tonemap SDR via CIToneMapHeadroom using a source headroom ratio and target headroom = 1.0 (SDR)
func tonemap_sdr(from hdr: CIImage, headroom_ratio: Float) -> CIImage? {
    hdr.applyingFilter("CIToneMapHeadroom",
                       parameters: ["inputSourceHeadroom": headroom_ratio,
                                    "inputTargetHeadroom": 1.0])
}

// -----------------------------------------------------------------------------
// Per-file processing setup
// -----------------------------------------------------------------------------

let linear_p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx_linear_p3 = CIContext(options: [.workingColorSpace: linear_p3,
                                        .outputColorSpace: linear_p3])

let encode_ctx = CIContext()

let p3_cs = CGColorSpace(name: CGColorSpace.displayP3)!
let hdr_required = CGColorSpace.displayP3_PQ as String

// Find all PNG files in input_HDR
let hdr_files: [URL]
do {
    hdr_files = try FileManager.default
        .contentsOfDirectory(at: input_hdr_dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    fputs("Cannot list input_HDR: \(error)\n", stderr); exit(73)
}

if hdr_files.isEmpty {
    fputs("No PNG files found in \(input_hdr_dir.path)\n", stderr)
    exit(0)
}

// -----------------------------------------------------------------------------
// Main loop
// -----------------------------------------------------------------------------
for hdr_url in hdr_files {
    autoreleasepool {
        let basename = hdr_url.deletingPathExtension().lastPathComponent
        let sdr_url = input_sdr_dir.appendingPathComponent(basename).appendingPathExtension("png")
        let out_url = output_dir
            .appendingPathComponent(basename + options.output_suffix)
            .appendingPathExtension("heic")
        fputs("Processing \(basename)…\n", stderr)

        // Load HDR
        guard let hdr = CIImage(contentsOf: hdr_url, options: [.expandToHDR: true]) else {
            fputs("  ! Cannot read HDR: \(hdr_url.path)\n", stderr); return
        }
        guard let hdr_cs = cs_name(hdr.colorSpace), hdr_cs == hdr_required else {
            fputs("  ! HDR colorspace not Display P3 PQ (got: \(cs_name(hdr.colorSpace) ?? "nil"))\n", stderr); return
        }

        // --- headroom measurement (for tonemap + maker apple) ---
        let pic_headroom: Float
        let headroom_ratio: Float

        if options.use_percentile {
            // Percentile method
            guard let h = percentile_headroom(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3,
                                              bins: CI_HISTOGRAM_MAX_BINS, percentile: options.peak_percentile) else {
                fputs("  ! Cannot compute percentile headroom\n", stderr); return
            }
            pic_headroom = h
            headroom_ratio = pic_headroom

            let abs_max_peak = max_luminance_hdr(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3) ?? pic_headroom
            fputs(String(format: "  • Percentile %.3f -> headroom %.3fx (max-peak=%.3fx)\n",
                         options.peak_percentile, pic_headroom, abs_max_peak), stderr)
        } else {
            // Peak-max method (default)
            guard let h = max_luminance_hdr(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3) else {
                fputs("  ! Cannot compute luminance peak\n", stderr); return
            }
            pic_headroom = h
            headroom_ratio = max(1.0, 1.0 + pic_headroom - powf(pic_headroom, options.tonemap_ratio))
            fputs(String(format: "  • Max-peak=%.3fx -> headroom_ratio=%.3f (tonemap_ratio=%.3f)\n",
                         pic_headroom, headroom_ratio, options.tonemap_ratio), stderr)
        }

        if options.tonemap_dryrun {
            if let clip = fraction_above_headroom_threshold(from: hdr,
                                                            context: ctx_linear_p3,
                                                            linear_cs: linear_p3,
                                                            threshold_headroom: headroom_ratio,
                                                            bins: 2048) {
                fputs(String(format: "  [dryrun] Pixels above headroom (%.3fx): %.3f%% (≈%.0f / %.0f)\n",
                             headroom_ratio, clip.fraction * 100.0, clip.clipped_pixels, clip.total_pixels), stderr)
            } else {
                fputs(String(format: "  [dryrun] Pixels above headroom (%.3fx): <n/a> (≈<n/a> / <n/a>)\n",
                             headroom_ratio), stderr)
            }
            return
        }

        // Choose pipeline: use provided SDR if present, otherwise tonemap
        let has_sdr = FileManager.default.fileExists(atPath: sdr_url.path)
        let sdr_base: CIImage
        if has_sdr {
            fputs("  Found SDR counterpart, using it as base image\n", stderr)
            if options.emit_clip_mask || options.emit_masked_image {
                fputs("  (warning) SDR provided on disk; --emit_clip_mask / --emit_masked_image are ignored because they only apply to the tool’s own tonemapped SDR.\n", stderr)
            }
            guard let sdr = CIImage(contentsOf: sdr_url) else {
                fputs("  ! Cannot read SDR: \(sdr_url.path)\n", stderr); return
            }
            let hdr_orient = (hdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            let sdr_orient = (sdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            guard hdr_orient == sdr_orient else {
                fputs("  ! Orientation mismatch (HDR=\(hdr_orient), SDR=\(sdr_orient))\n", stderr); return
            }
            guard hdr.extent.size == sdr.extent.size else {
                fputs("  ! Size mismatch (HDR=\(hdr.extent.size), SDR=\(sdr.extent.size))\n", stderr); return
            }
            guard let sdr_cs = cs_name(sdr.colorSpace), sdr_cs == CGColorSpace.displayP3 as String else {
                fputs("  ! SDR colorspace not Display P3 (got: \(cs_name(sdr.colorSpace) ?? "nil"))\n", stderr); return
            }
            sdr_base = sdr
        } else {
            fputs("  SDR image not found, producing one by tonemapping\n", stderr)
            if options.emit_clip_mask {
                _ = write_clip_mask_no_kernel(hdr: hdr,
                                                  threshold_headroom: headroom_ratio,
                                                  ctx: encode_ctx,
                                                  out_url: out_url)
            }
            guard let sdr = tonemap_sdr(from: hdr, headroom_ratio: headroom_ratio) else {
                fputs("  ! Tonemapping failed\n", stderr); return
            }

            if let clip = fraction_above_headroom_threshold(from: hdr,
                                                            context: ctx_linear_p3,
                                                            linear_cs: linear_p3,
                                                            threshold_headroom: headroom_ratio,
                                                            bins: CI_HISTOGRAM_MAX_BINS) {
                fputs(String(format: "  • Pixels above headroom (%.3fx): %.3f%% (≈%.0f px)\n",
                             headroom_ratio, clip.fraction * 100.0, clip.total_pixels * clip.fraction), stderr)
            } else {
                fputs("  • Clip fraction: <n/a>\n", stderr)
            }

            sdr_base = sdr

            if options.emit_masked_image && !options.tonemap_dryrun {
                if let clip_mask = build_clip_mask_image_no_kernel(hdr: hdr, threshold_headroom: headroom_ratio) {
                    let color = parse_color(options.masked_color)
                    _ = write_masked_sdr_image(sdr_base: sdr_base,
                                               mask: clip_mask,
                                               solid: color,
                                               ctx: encode_ctx,
                                               out_url: out_url)
                } else {
                    fputs("  ! Failed to build clip mask (overlay skipped)\n", stderr)
                }
            }
        }

        // Maker Apple metadata
        let maker = maker_apple_from_headroom(pic_headroom)
        guard let chosen = maker.default else {
            fputs("  ! No valid makerApple pair for headroom=\(pic_headroom)\n", stderr); return
        }

        let headroom_for_meta = powf(2.0, max(maker.stops, 0.0))
        let val = validate_maker_apple(headroom_linear: headroom_for_meta,
                                       maker33: chosen.maker33,
                                       maker48: chosen.maker48,
                                       tol_stops_abs: 0.01,
                                       tol_headroom_rel: 0.02)
        if let d = val.diffs, !val.ok {
            fputs(String(format: "  ! makerApple validation failed (branch=%@, Δstops=%.4f, relΔ=%.2f%%)\n",
                         d.branch, d.abs_stops_diff, d.rel_headroom_diff*100), stderr)
            return
        }
        if pic_headroom > 8.0 {
            fputs(String(format: "  • Headroom %.3f× exceeds metadata limit (8×). Clamped makerApple to 8×.\n", pic_headroom), stderr)
        }

        // Build temp HEIC to get the gain map
        let tmp_options: [CIImageRepresentationOption : Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
            CIImageRepresentationOption.hdrImage: hdr,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        guard let tmp_data = encode_ctx.heifRepresentation(of: sdr_base,
                                                           format: .RGB10,
                                                           colorSpace: p3_cs,
                                                           options: tmp_options) else {
            fputs("  ! Failed to build temp HEIC\n", stderr); return
        }

        guard let gain_map = CIImage(data: tmp_data, options: [.auxiliaryHDRGainMap: true]) else {
            fputs("  ! Failed to extract gain map from temp HEIC\n", stderr); return
        }

        // Apply Maker Apple metadata
        var props = hdr.properties
        var maker_apple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker_apple["33"] = chosen.maker33
        maker_apple["48"] = chosen.maker48
        props[kCGImagePropertyMakerAppleDictionary as String] = maker_apple
        let sdr_with_props = sdr_base.settingProperties(props)

        let export_options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.heic_compression_quality,
            CIImageRepresentationOption.hdrGainMapImage: gain_map,
            CIImageRepresentationOption.hdrGainMapAsRGB: false
        ]
        do {
            try encode_ctx.writeHEIFRepresentation(of: sdr_with_props,
                                                   to: out_url,
                                                   format: .RGB10,
                                                   colorSpace: p3_cs,
                                                   options: export_options)
            fputs("  ✔ Wrote: \(out_url.path)\n", stderr)
        } catch {
            fputs("  ! Export failed: \(error)\n", stderr)
        }
    }
}

fputs("Done.\n", stderr)
