import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// -----------------------------------------------------------------------------
// Thread-Safe Logger
// -----------------------------------------------------------------------------

final class Logger {
    private let queue = DispatchQueue(label: "logger.serial")
    private let showDebug: Bool
    private let verbose: Bool
    private let writeLog: Bool
    private let logFileURL: URL?
    private let enableColor: Bool
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    init(debug: Bool, verbose: Bool = false, writeLog: Bool = false, logFile: String? = nil, enableColor: Bool = true) {
        self.showDebug = debug
        self.verbose = verbose
        self.writeLog = writeLog
        // Colors active only if required and if stderr is a TTY
        self.enableColor = enableColor && isatty(fileno(stderr)) != 0
        if let path = logFile, writeLog {
            self.logFileURL = URL(fileURLWithPath: path)
        } else {
            self.logFileURL = nil
        }
    }
    
    func log(_ message: String, file: String? = nil, level: LogLevel = .info) {
        queue.async {
            var fullMessage = self.makePrefix(file: file, level: level) + message + "\n"
            if self.enableColor {
                 fullMessage = self.colorize(fullMessage, level: level)
            }
            // Write to log file if enabled
            if self.writeLog, let url = self.logFileURL {
                self.appendToLogFile(fullMessage, url: url)
            }
            
            // Print to stderr only if verbose
            if self.verbose {
                fputs(fullMessage, stderr)
            }
        }
    }
    
    private func colorize(_ s: String, level: LogLevel) -> String {
        let reset = "\u{001B}[0m"
        let code: String
        switch level {
        case .success: code = "\u{001B}[32m" // green
        case .warning: code = "\u{001B}[33m" // yellow
        case .error:   code = "\u{001B}[31m" // red
        case .debug:   code = "\u{001B}[90m" // grey
        case .info:    code = ""             // neutral
        }
        return code.isEmpty ? s : code + s + reset
    }
    
    func debug(_ message: String, file: String? = nil) {
        guard showDebug else { return }
        log(message, file: file, level: .debug)
    }
    
    private func appendToLogFile(_ message: String, url: URL) {
        let data = message.data(using: .utf8) ?? Data()
        
        if !FileManager.default.fileExists(atPath: url.path) {
            // Create file with session header
            let header = "\n=== Session started at \(Date()) ===\n"
            let headerData = header.data(using: .utf8) ?? Data()
            try? headerData.write(to: url)
        }
        
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        }
    }
    
    private func makePrefix(file: String?, level: LogLevel) -> String {
        var components: [String] = []
        
        components.append("[\(Logger.timeFormatter.string(from: Date()))]")
        components.append(level.emoji)
        
        if let file = file {
            components.append("[\(file)]")
        }
        
        return components.joined(separator: " ") + " "
    }
    
    enum LogLevel {
        case info, success, warning, error, debug
        
        var emoji: String {
            switch self {
            case .info:    return "•"
            case .success: return "✔"
            case .warning: return "⚠"
            case .error:   return "✗"
            case .debug:   return "🔍"
            }
        }
    }
}

final class RunStats {
    private let q = DispatchQueue(label: "runstats.serial")
    private(set) var total = 0
    private(set) var written = 0
    private(set) var skipped: [(file: String, reason: String)] = []
    private(set) var failed:  [(file: String, reason: String)] = []
    
    func setTotal(_ n: Int) { q.sync { total = n } }
    func incWritten() { q.sync { written += 1 } }
    func addSkipped(_ f: String, _ why: String) { q.sync { skipped.append((f, why)) } }
    func addFailed(_ f: String, _ why: String)  { q.sync { failed.append((f, why)) } }
}

func printSummary(stats: RunStats, color: Bool) {
    let red    = color ? "\u{001B}[31m" : ""
    let yellow = color ? "\u{001B}[33m" : ""
    let green  = color ? "\u{001B}[32m" : ""
    let bold   = color ? "\u{001B}[1m"  : ""
    let reset  = color ? "\u{001B}[0m"  : ""
    
    let failedCount  = stats.failed.count
    let skippedCount = stats.skipped.count
    let written      = stats.written
    let total        = stats.total
    
    fputs("\n\(bold)======== Summary ========\(reset)\n", stderr)
    fputs("Total HDR files: \(total)\n", stderr)
    fputs("\(green)Written: \(written)\(reset)\n", stderr)
    fputs("\(yellow)Skipped: \(skippedCount)\(reset)\n", stderr)
    fputs("\(red)Failed:  \(failedCount)\(reset)\n", stderr)
    
    if skippedCount > 0 {
        fputs("\n\(yellow)Skipped files:\(reset)\n", stderr)
        for item in stats.skipped {
            fputs("  • \(item.file) — \(item.reason)\n", stderr)
        }
    }
    if failedCount > 0 {
        fputs("\n\(red)Failed files:\(reset)\n", stderr)
        for item in stats.failed {
            fputs("  • \(item.file) — \(item.reason)\n", stderr)
        }
    }
    fputs("\(bold)==========================\(reset)\n", stderr)
}

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------
let input_hdr_dir  = URL(fileURLWithPath: "./input_HDR/", isDirectory: true)
let input_sdr_dir  = URL(fileURLWithPath: "./input_SDR/", isDirectory: true)
let output_dir     = URL(fileURLWithPath: "./output_HDR_with_gainmap/", isDirectory: true)
let output_clipped_mask_dir    = URL(fileURLWithPath: "./output_clipped_mask/", isDirectory: true)
let output_clipped_overlay_dir = URL(fileURLWithPath: "./output_clipped_overlay/", isDirectory: true)

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
    var parallel: Bool = false
    var max_concurrent: Int = ProcessInfo.processInfo.activeProcessorCount
    var verbose: Bool = false
    var write_log: Bool = false
    var log_file: String = "./hdr2gainmap.log"
    var no_color: Bool = false
    var do_not_verify: Bool = false
}

@discardableResult
func print_usage(_ prog: String) -> Int32 {
    fputs("""
    Usage:
      \(prog) [--suffix <text>] [--peak_percentile [value]] [--peak_max]
             [--tonemap_ratio <0..1>] [--heic_compression_quality <0..1>]
             [--tonemap_dryrun] [--emit_clip_mask] [--emit_masked_image [color]]
             [--parallel] [--max_concurrent <n>]
             [--verbose] [--write_log [path]] [--do_not_verify] [--no_color] [--debug]

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
      --parallel                      Enable parallel processing of files
      --max_concurrent <n>            Max concurrent file processing (default: CPU count)
      --verbose                       Print detailed log messages to stderr (disables progress bar)
      --write_log [path]              Write log messages to file (default: ./hdr2gainmap.log)
                                      Progress bar remains active unless --verbose is also used
      --no_color                      Disable ANSI colors in console output
      --do_not_verify                 Skip post-export gain-map verification (default: verify)
      --debug                         Print verbose debug messages (implies --verbose)
      --help                          Show this message

    Logging Behavior:
      • Default:         Progress bar only, no console output
      • --verbose:       Detailed console output, no progress bar
      • --write_log:     Log to file + progress bar
      • --debug:         Debug mode implies --verbose (console output, no progress bar)

    """, stderr)
    return 64
}

func parse_options(_ argv: [String]) -> Options {
    var opts = Options()
    let allowed = Set([
        "--suffix","--peak_percentile","--peak_max","--tonemap_ratio",
        "--heic_compression_quality",
        "--tonemap_dryrun","--emit_clip_mask","--emit_masked_image",
        "--parallel","--max_concurrent",
        "--verbose","--write_log","--no_color","--do_not_verify","--debug","--help"
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

        case "--parallel":
            opts.parallel = true
            i += 1

        case "--max_concurrent":
            guard i+1 < n, !argv[i+1].hasPrefix("-"),
                  let v = Int(argv[i+1]), v > 0 else {
                fputs("Option --max_concurrent requires a positive integer.\n", stderr)
                exit(print_usage(prog))
            }
            opts.max_concurrent = v
            i += 2

        case "--verbose":
            opts.verbose = true
            i += 1

        case "--write_log":
            opts.write_log = true
            if i+1 < n, !argv[i+1].hasPrefix("-") {
                opts.log_file = argv[i+1]
                i += 2
            } else {
                i += 1
            }
            
        case "--no_color":
            opts.no_color = true
            i += 1
            
        case "--do_not_verify":
            opts.do_not_verify = true
            i += 1

        case "--debug":
            opts.debug = true
            opts.verbose = true  // debug implies verbose
            i += 1

        default:
            fputs("Unhandled option: \(tok)\n", stderr); exit(print_usage(prog))
        }
    }
    return opts
}

let options = parse_options(CommandLine.arguments)
let logger = Logger(debug: options.debug,
                    verbose: options.verbose,
                    writeLog: options.write_log,
                    logFile: options.log_file,
                    enableColor: !options.no_color)

/// Progress bar
final class ProgressBar {
    private let queue = DispatchQueue(label: "progressbar.serial")
    private var current: Int = 0
    private let total: Int
    private let enabled: Bool
    private let width: Int = 40
    private var hasPrintedInitial = false
    
    init(total: Int, enabled: Bool) {
        self.total = total
        self.enabled = enabled
    }
    
    /// Prints progress bar immediatly @0% (before any job finishes)
    func showInitial(fileName: String? = nil) {
         guard enabled else { return }
         queue.sync {
            // evita doppie stampe dello 0% se chiamata più volte
            guard !hasPrintedInitial else { return }
            hasPrintedInitial = true
            self.render(fileName: fileName)
        }
    }
    
    func increment(fileName: String? = nil) {
        guard enabled else { return }
        
        queue.sync {
            self.current += 1
            self.render(fileName: fileName)
        }
    }
    
    private func render(fileName: String?) {
        let percentage = Float(current) / Float(total)
        let filled = Int(percentage * Float(width))
        let empty = width - filled
        
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        let percent = String(format: "%.1f%%", percentage * 100)
        
        var line = "\r[\(bar)] \(current)/\(total) (\(percent))"
        if let file = fileName {
            line += " - \(file)"
        }
        
        // Pad with spaces to clear previous text
        line += String(repeating: " ", count: 20)
        
        fputs(line, stderr)
        fflush(stderr)
        
        if current >= total {
            fputs("\n", stderr)
        }
    }
    
    func finish() {
        guard enabled else { return }
        // Flush: make sure that queued renders if any are completed
        queue.sync { /* no-op */ }
        fputs("\n", stderr)
        fflush(stderr)
    }
}

// Early folder validation
var is_dir: ObjCBool = false
guard FileManager.default.fileExists(atPath: input_hdr_dir.path, isDirectory: &is_dir), is_dir.boolValue else {
    logger.log("Missing folder: \(input_hdr_dir.path)", level: .error)
    exit(73)
}
if !FileManager.default.fileExists(atPath: output_dir.path, isDirectory: &is_dir) {
    do {
        try FileManager.default.createDirectory(at: output_dir, withIntermediateDirectories: true)
        logger.log("Created output directory: \(output_dir.path)")
    }
    catch {
        logger.log("Cannot create output dir: \(error)", level: .error)
        exit(73)
    }
}

if options.use_percentile && options.debug {
    logger.debug("Note: --tonemap_ratio is ignored with --peak_percentile.")
}

// Create optional output folders
if options.emit_clip_mask {
    var is_dir2: ObjCBool = false
    if !FileManager.default.fileExists(atPath: output_clipped_mask_dir.path, isDirectory: &is_dir2) {
        do {
            try FileManager.default.createDirectory(at: output_clipped_mask_dir, withIntermediateDirectories: true)
            logger.log("Created clip mask directory: \(output_clipped_mask_dir.path)")
        }
        catch {
            logger.log("Cannot create output_clipped_mask dir: \(error)", level: .error)
            exit(73)
        }
    }
}
if options.emit_masked_image {
    var is_dir3: ObjCBool = false
    if !FileManager.default.fileExists(atPath: output_clipped_overlay_dir.path, isDirectory: &is_dir3) {
        do {
            try FileManager.default.createDirectory(at: output_clipped_overlay_dir, withIntermediateDirectories: true)
            logger.log("Created overlay directory: \(output_clipped_overlay_dir.path)")
        }
        catch {
            logger.log("Cannot create output_clipped_overlay dir: \(error)", level: .error)
            exit(73)
        }
    }
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

/// Check for gain map
@Sendable
func verifyGainMap(at url: URL, fileName: String) -> Bool {
    // Se riusciamo a leggere l’immagine ausiliaria HDR gain map, allora è presente.
    if let _ = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true]) {
        logger.debug("Gain map verified present", file: fileName)
        return true
    } else {
        return false
    }
}

/// Parse a color string into CIColor. Accepts simple names or "#RRGGBB".
@Sendable
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
@Sendable
func cs_name(_ cs: CGColorSpace?) -> String? {
    guard let cs = cs, let name = cs.name else { return nil }
    return name as String
}

/// Put linear luminance (Y) in R; zero G/B; A=1.
@Sendable
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
@Sendable
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
@Sendable
func percentile_headroom(from ci_image: CIImage,
                         context: CIContext,
                         linear_cs: CGColorSpace,
                         bins: Int = 1024,
                         percentile: Float = 99.9,
                         fileName: String? = nil) -> Float? {
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
    logger.debug(String(format:
      "percentile_headroom: bins=%d absMax=%.6f target=%.1f%% k=%d vNorm=%.6f CDF=%.4f yPercentile=%.6f headroom=%.6f",
      bin_count, abs_max, Double(percentile), k, v_norm, reached, Double(y_percentile), Double(max(y_percentile, 1.0))
    ), file: fileName)

    return max(y_percentile, 1.0)
}

/// Fraction of pixels with linear luminance above a threshold (headroom).
@Sendable
func fraction_above_headroom_threshold(from ci_image: CIImage,
                                       context: CIContext,
                                       linear_cs: CGColorSpace,
                                       threshold_headroom: Float,
                                       bins: Int = 1024,
                                       fileName: String? = nil)
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

    logger.debug(String(format:
      "fraction_above_headroom_threshold: absMax=%.6f thr=%.6f thrNorm=%.6f binCount=%d thrBin=%d aboveIncl=%.0f total=%.0f frac=%.6f",
      abs_max, Double(threshold_headroom), thr_norm, bin_count, thr_bin, above_incl, total_hist, frac
    ), file: fileName)

    return (frac, clipped_px, total_px)
}

/// Get pixel count using metadata width/height when available; fallback to extent.
@Sendable
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
@Sendable
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
@discardableResult @Sendable
func write_clip_mask_no_kernel(hdr: CIImage,
                                   threshold_headroom: Float,
                                   ctx: CIContext,
                                   out_url: URL,
                                   fileName: String) -> URL? {
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
        logger.log("Wrote clip mask: \(heic_url.lastPathComponent)", file: fileName, level: .success)
        return heic_url
    } catch {
        logger.log("Failed to write clip mask: \(error)", file: fileName, level: .error)
        return nil
    }
}

/// Write an SDR image where clipped pixels are replaced with a solid color.
@discardableResult @Sendable
func write_masked_sdr_image(sdr_base: CIImage,
                            mask: CIImage,
                            solid: CIColor,
                            ctx: CIContext,
                            out_url: URL,
                            fileName: String) -> URL? {
    guard let gen = CIFilter(name: "CIConstantColorGenerator") else {
        logger.log("CIConstantColorGenerator not available", file: fileName, level: .error)
        return nil
    }
    gen.setValue(solid, forKey: kCIInputColorKey)
    guard let color_infinite = gen.outputImage else {
        logger.log("constantColorGenerator failed", file: fileName, level: .error)
        return nil
    }
    let color_img = color_infinite.cropped(to: sdr_base.extent)

    guard let blend = CIFilter(name: "CIBlendWithMask") else {
        logger.log("CIBlendWithMask not available", file: fileName, level: .error)
        return nil
    }
    blend.setValue(color_img, forKey: kCIInputImageKey)
    blend.setValue(sdr_base,  forKey: kCIInputBackgroundImageKey)
    blend.setValue(mask,      forKey: kCIInputMaskImageKey)
    guard let overlaid = blend.outputImage else {
        logger.log("blendWithMask failed", file: fileName, level: .error)
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
        logger.log("Wrote masked overlay: \(heic_url.lastPathComponent)", file: fileName, level: .success)
        return heic_url
    } catch {
        logger.log("Failed to write masked overlay: \(error)", file: fileName, level: .error)
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

@Sendable
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

@Sendable
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

@Sendable
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
@Sendable
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
    logger.log("Cannot list input_HDR: \(error)", level: .error)
    exit(73)
}

if hdr_files.isEmpty {
    logger.log("No PNG files found in \(input_hdr_dir.path)", level: .warning)
    exit(0)
}

logger.log("Found \(hdr_files.count) HDR file(s) to process")
if options.parallel {
    logger.log("Parallel processing enabled (max \(options.max_concurrent) concurrent)")
}

let stats = RunStats()
stats.setTotal(hdr_files.count)

// Progress bar enabled only if NOT verbose
let progressBar = ProgressBar(total: hdr_files.count,
                             enabled: !options.verbose)

// Display progress bar @0%
progressBar.showInitial()

// -----------------------------------------------------------------------------
// Main processing function
// -----------------------------------------------------------------------------

func process_file(_ hdr_url: URL, index: Int, total: Int) {
    autoreleasepool {
        let fileName = hdr_url.deletingPathExtension().lastPathComponent
        let sdr_url = input_sdr_dir.appendingPathComponent(fileName).appendingPathExtension("png")
        let out_url = output_dir
            .appendingPathComponent(fileName + options.output_suffix)
            .appendingPathExtension("heic")
        
        logger.log("Processing [\(index)/\(total)]…", file: fileName)

        // Load HDR
        guard let hdr = CIImage(contentsOf: hdr_url, options: [.expandToHDR: true]) else {
            logger.log("Cannot read HDR: \(hdr_url.path)", file: fileName, level: .error)
            stats.addFailed(fileName, "Cannot read HDR")
            return
        }
        guard let hdr_cs = cs_name(hdr.colorSpace), hdr_cs == hdr_required else {
            logger.log("HDR colorspace not Display P3 PQ (got: \(cs_name(hdr.colorSpace) ?? "nil"))",
                      file: fileName, level: .error)
            stats.addSkipped(fileName, "Wrong HDR colorspace (expected Display P3 PQ)")
            return
        }

        // --- headroom measurement ---
        let pic_headroom: Float
        let headroom_ratio: Float

        if options.use_percentile {
            guard let h = percentile_headroom(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3,
                                              bins: CI_HISTOGRAM_MAX_BINS, percentile: options.peak_percentile,
                                              fileName: fileName) else {
                logger.log("Cannot compute percentile headroom", file: fileName, level: .error)
                return
            }
            pic_headroom = h
            headroom_ratio = pic_headroom

            let abs_max_peak = max_luminance_hdr(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3) ?? pic_headroom
            logger.log(String(format: "Percentile %.1f%% → headroom %.3fx (max-peak=%.3fx)",
                         options.peak_percentile, pic_headroom, abs_max_peak), file: fileName)
        } else {
            guard let h = max_luminance_hdr(from: hdr, context: ctx_linear_p3, linear_cs: linear_p3) else {
                logger.log("Cannot compute luminance peak", file: fileName, level: .error)
                return
            }
            pic_headroom = h
            headroom_ratio = max(1.0, 1.0 + pic_headroom - powf(pic_headroom, options.tonemap_ratio))
            logger.log(String(format: "Max-peak=%.3fx → headroom_ratio=%.3f (tonemap_ratio=%.3f)",
                         pic_headroom, headroom_ratio, options.tonemap_ratio), file: fileName)
        }

        if options.tonemap_dryrun {
            if let clip = fraction_above_headroom_threshold(from: hdr,
                                                            context: ctx_linear_p3,
                                                            linear_cs: linear_p3,
                                                            threshold_headroom: headroom_ratio,
                                                            bins: 2048,
                                                            fileName: fileName) {
                logger.log(String(format: "[dryrun] Pixels above headroom (%.3fx): %.3f%% (≈%.0f / %.0f)",
                             headroom_ratio, clip.fraction * 100.0, clip.clipped_pixels, clip.total_pixels),
                          file: fileName)
            } else {
                logger.log(String(format: "[dryrun] Pixels above headroom (%.3fx): <n/a>", headroom_ratio),
                          file: fileName)
            }
            return
        }

        // Choose pipeline: use provided SDR if present, otherwise tonemap
        let has_sdr = FileManager.default.fileExists(atPath: sdr_url.path)
        let sdr_base: CIImage
        if has_sdr {
            logger.log("Found SDR counterpart, using it as base image", file: fileName)
            if options.emit_clip_mask || options.emit_masked_image {
                logger.log("SDR provided; --emit_clip_mask / --emit_masked_image ignored (debug overlays are only meaningful when SDR is tone-mapped by the tool)",
                          file: fileName, level: .warning)
            }
            guard let sdr = CIImage(contentsOf: sdr_url) else {
                logger.log("Cannot read SDR: \(sdr_url.path)", file: fileName, level: .error)
                stats.addFailed(fileName, "Cannot read SDR")
                return
            }
            let hdr_orient = (hdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            let sdr_orient = (sdr.properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
            guard hdr_orient == sdr_orient else {
                logger.log("Orientation mismatch (HDR=\(hdr_orient), SDR=\(sdr_orient))",
                          file: fileName, level: .error)
                stats.addSkipped(fileName, "Orientation mismatch")
                return
            }
            guard hdr.extent.size == sdr.extent.size else {
                logger.log("Size mismatch (HDR=\(hdr.extent.size), SDR=\(sdr.extent.size))",
                          file: fileName, level: .error)
                stats.addSkipped(fileName, "Size mismatch")
                return
            }
            guard let sdr_cs = cs_name(sdr.colorSpace), sdr_cs == CGColorSpace.displayP3 as String else {
                logger.log("SDR colorspace not Display P3 (got: \(cs_name(sdr.colorSpace) ?? "nil"))",
                          file: fileName, level: .error)
                stats.addSkipped(fileName, "Wrong SDR colorspace (expected Display P3)")
                return
            }
            sdr_base = sdr
        } else {
            logger.log("SDR image not found, producing one by tonemapping", file: fileName)
            if options.emit_clip_mask {
                _ = write_clip_mask_no_kernel(hdr: hdr,
                                              threshold_headroom: headroom_ratio,
                                              ctx: encode_ctx,
                                              out_url: out_url,
                                              fileName: fileName)
            }
            guard let sdr = tonemap_sdr(from: hdr, headroom_ratio: headroom_ratio) else {
                logger.log("Tonemapping failed", file: fileName, level: .error)
                return
            }

            if let clip = fraction_above_headroom_threshold(from: hdr,
                                                            context: ctx_linear_p3,
                                                            linear_cs: linear_p3,
                                                            threshold_headroom: headroom_ratio,
                                                            bins: CI_HISTOGRAM_MAX_BINS,
                                                            fileName: fileName) {
                logger.log(String(format: "Pixels above headroom (%.3fx): %.3f%% (≈%.0f px)",
                             headroom_ratio, clip.fraction * 100.0, clip.total_pixels * clip.fraction),
                          file: fileName)
            } else {
                logger.log("Clip fraction: <n/a>", file: fileName)
            }

            sdr_base = sdr

            if options.emit_masked_image {
                if let clip_mask = build_clip_mask_image_no_kernel(hdr: hdr, threshold_headroom: headroom_ratio) {
                    let color = parse_color(options.masked_color)
                    _ = write_masked_sdr_image(sdr_base: sdr_base,
                                               mask: clip_mask,
                                               solid: color,
                                               ctx: encode_ctx,
                                               out_url: out_url,
                                               fileName: fileName)
                } else {
                    logger.log("Failed to build clip mask (overlay skipped)", file: fileName, level: .warning)
                }
            }
        }

        // Maker Apple metadata
        let maker = maker_apple_from_headroom(pic_headroom)
        guard let chosen = maker.default else {
            logger.log("No valid makerApple pair for headroom=\(pic_headroom)", file: fileName, level: .error)
            return
        }

        let headroom_for_meta = powf(2.0, max(maker.stops, 0.0))
        let val = validate_maker_apple(headroom_linear: headroom_for_meta,
                                       maker33: chosen.maker33,
                                       maker48: chosen.maker48,
                                       tol_stops_abs: 0.01,
                                       tol_headroom_rel: 0.02)
        if let d = val.diffs, !val.ok {
            logger.log(String(format: "makerApple validation failed (branch=%@, Δstops=%.4f, relΔ=%.2f%%)",
                         d.branch, d.abs_stops_diff, d.rel_headroom_diff*100),
                      file: fileName, level: .error)
            return
        }
        if pic_headroom > 8.0 {
            logger.log(String(format: "Headroom %.3fx exceeds metadata limit (8×). Clamped makerApple to 8×.",
                       pic_headroom), file: fileName, level: .warning)
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
            logger.log("Failed to build temp HEIC", file: fileName, level: .error)
            stats.addFailed(fileName, "Failed to build temp HEIC")
            return
        }

        guard let gain_map = CIImage(data: tmp_data, options: [.auxiliaryHDRGainMap: true]) else {
            logger.log("Failed to extract gain map from temp HEIC", file: fileName, level: .error)
            stats.addFailed(fileName, "No gain map extracted")
            return
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
            logger.log("Wrote: \(out_url.lastPathComponent)", file: fileName, level: .success)
       
            // Post-export verification (enabled by default; can be skipped via --do_not_verify)
            if !options.do_not_verify {
               if !verifyGainMap(at: out_url, fileName: fileName) {
                   logger.log("Gain map might be missing in output!", file: fileName, level: .warning)
               }
            }
        } catch {
            logger.log("Export failed: \(error)", file: fileName, level: .error)
        }
    }
}

// -----------------------------------------------------------------------------
// Main loop
// -----------------------------------------------------------------------------

if options.parallel {
    let queue = DispatchQueue(label: "hdr.processing", attributes: .concurrent)
    let semaphore = DispatchSemaphore(value: options.max_concurrent)
    
    for (index, hdr_url) in hdr_files.enumerated() {
        semaphore.wait()
        queue.async {
        defer {
                let fileName = hdr_url.deletingPathExtension().lastPathComponent
                progressBar.increment(fileName: fileName)
                semaphore.signal()
            }
            process_file(hdr_url, index: index + 1, total: hdr_files.count)
        }
    }
    
    queue.sync(flags: .barrier) {}
    progressBar.finish()
} else {
    for (index, hdr_url) in hdr_files.enumerated() {
        process_file(hdr_url, index: index + 1, total: hdr_files.count)
        let fileName = hdr_url.deletingPathExtension().lastPathComponent
        progressBar.increment(fileName: fileName)
    }
    progressBar.finish()
}

printSummary(stats: stats, color: !options.no_color && isatty(fileno(stderr)) != 0)
logger.log("Done.", level: .success)
