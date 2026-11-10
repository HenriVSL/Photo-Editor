//
//  DevSelfCheck.swift
//  Photo Editor
//
//  DEVELOPMENT ONLY.
//
//  Runs the real pipeline over the bundled sample images on device and writes
//  a report plus PNGs into the app's Documents directory, where they can be
//  pulled off with:
//
//      xcrun devicectl device copy from --device <id> \
//          --domain-type appDataContainer --domain-identifier henril.Photo-Editor \
//          --source Documents/SelfCheck --destination ./out
//
//  This exists because the development Mac's GPU can't run Core Image Metal
//  kernels at all, so the only way to see whether the shaders and the raw
//  path actually work is to measure it on the device itself.
//
//  Delete this file and `Photo Editor/DevSamples/` to remove.
//

#if DEBUG

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

enum DevSelfCheck {

    private static let log = Logger(subsystem: "henril.Photo-Editor", category: "SelfCheck")

    /// Only runs when explicitly asked for, via
    ///
    ///     xcrun devicectl device process launch --device <id> \
    ///         --environment-variables '{"PHOTO_EDITOR_SELFCHECK":"1"}' henril.Photo-Editor
    ///
    /// A full pass is ~30 seconds of solid GPU work against the same CIContext
    /// the UI renders through, so on a normal launch it makes the whole app
    /// look frozen — every button appears dead until it finishes.
    /// `1`/`full` runs everything; `base` runs only the fast diagnostics.
    /// A full pass is enough solid GPU work that if the app goes to the
    /// background mid-run, iOS kills it for a scene-update watchdog timeout —
    /// so keep focused runs focused.
    static var mode: String? {
        ProcessInfo.processInfo.environment["PHOTO_EDITOR_SELFCHECK"]
    }

    static var runsAtLaunch: Bool { mode != nil }

    private static var isFullRun: Bool { mode == "1" || mode == "full" }

    nonisolated static func run() async {
        let started = Date()
        var report = ""
        func emit(_ line: String) {
            report += line + "\n"
            log.info("\(line, privacy: .public)")
        }

        let outputDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfCheck", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDirectory)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        emit("Photo Editor self-check — \(Date().formatted(date: .abbreviated, time: .standard))")
        emit("")
        var problemsFromColorCheck = 0

        // MARK: Kernels

        let kernels = CIKernelLibrary.shared
        emit("Metal kernels loaded: \(kernels.isComplete ? "ALL" : "INCOMPLETE")")
        if !kernels.isComplete {
            let missing = [
                ("wbExposure", kernels.wbExposure == nil),
                ("basicTone", kernels.basicTone == nil),
                ("colorMixer", kernels.colorMixer == nil),
                ("colorGrade", kernels.colorGrade == nil),
                ("clarityTexture", kernels.clarityTexture == nil),
                ("dehaze", kernels.dehaze == nil),
                ("sharpen", kernels.sharpen == nil),
                ("colorNoiseReduction", kernels.colorNoiseReduction == nil),
                ("darkChannel", kernels.darkChannel == nil),
                ("postCropVignette", kernels.postCropVignette == nil),
                ("filmGrain", kernels.filmGrain == nil),
            ].filter(\.1).map(\.0)
            emit("  MISSING: \(missing.joined(separator: ", "))")
        }
        emit("")

        // MARK: Colour invariants

        problemsFromColorCheck = DevColorCheck.run(emit: emit)
        emit("")

        let engine = RenderEngine.shared
        var problems = problemsFromColorCheck

        // MARK: Base rendering comparison
        //
        // An Apple ProRAW DNG embeds Apple's own profile, carrying the Smart
        // HDR tone mapping that makes these files look good out of camera.
        // We currently strip it (boostAmount = 0) to get linear data and then
        // approximate a base curve — this renders the alternatives side by
        // side so the cost of that choice is visible.

        if let rawURL = Bundle.main.url(forResource: "IMG_4169", withExtension: "DNG") {
            emit("Base rendering comparison (what the image looks like before any slider)")

            func renderBase(
                _ label: String,
                usingOurBaseCurve: Bool,
                configure: (CIRAWFilter) -> Void
            ) {
                guard let filter = CIRAWFilter(imageURL: rawURL) else { return }
                filter.isDraftModeEnabled = true
                filter.scaleFactor = Float(900 / max(filter.nativeSize.width, filter.nativeSize.height))
                configure(filter)

                guard let decoded = filter.outputImage else {
                    emit("   FAIL \(label): decode returned nil")
                    problems += 1
                    return
                }

                // Our path runs the pipeline (which adds the base curve for
                // raw); Apple's renderings are already display-referred, so
                // they go straight out.
                let image: CIImage
                if usingOurBaseCurve {
                    var neutral = EditSettings()
                    neutral.isRawTemperature = true
                    neutral.colorNR = 25
                    image = engine.process(decoded, settings: neutral, isRaw: true)
                } else {
                    image = decoded
                }

                guard let cg = engine.makeCGImage(image) else { return }
                let stats = luminanceStats(cg)
                let rgb = meanRGB(cg)
                writePNG(cg, to: outputDirectory.appendingPathComponent("base-\(label).png"))
                emit(String(
                    format: "   %-22@ mean %.3f  min %.3f  max %.3f   RGB %.3f %.3f %.3f",
                    label as NSString, stats.mean, stats.min, stats.max, rgb.r, rgb.g, rgb.b
                ))
            }

            // What we ship today.
            renderBase("ours-linear+curve", usingOurBaseCurve: true) { filter in
                filter.boostAmount = 0
                filter.boostShadowAmount = 0
                filter.localToneMapAmount = 0
                filter.sharpnessAmount = 0
                filter.detailAmount = 0
                filter.contrastAmount = 0
                filter.extendedDynamicRangeAmount = 0
                filter.isGamutMappingEnabled = false
            }

            // Apple's full rendering — CIRAWFilter left entirely alone. This is
            // the closest equivalent to Lightroom's "Apple ProRAW" profile.
            renderBase("apple-default", usingOurBaseCurve: false) { _ in }

            // Apple's global tone curve but no local tone mapping, which is
            // the more neutral starting point of the two.
            renderBase("apple-no-localtone", usingOurBaseCurve: false) { filter in
                filter.localToneMapAmount = 0
            }

            // Apple's tone curve with their sharpening/NR suppressed, so only
            // the rendering differs from ours rather than the detail handling.
            renderBase("apple-tone-only", usingOurBaseCurve: false) { filter in
                filter.localToneMapAmount = 0
                filter.sharpnessAmount = 0
                filter.detailAmount = 0
            }

            // Through the shipping pipeline at both profiles, at a fixed long
            // edge so a Lightroom export can be downsampled to match and the
            // two compared pixel for pixel.
            for rendering in RawRendering.allCases {
                var neutral = EditSettings()
                neutral.isRawTemperature = true
                neutral.colorNR = 25
                neutral.rawRendering = rendering

                guard let source = ImageSource(url: rawURL),
                      let decoded = source.makeBaseImage(
                        settings: neutral, maxDimension: 1344, draft: false
                      )
                else { continue }

                let processed = engine.process(decoded, settings: neutral, isRaw: true)
                guard let cg = engine.makeCGImage(processed) else { continue }

                let slug = rendering.rawValue.replacingOccurrences(of: " ", with: "-")
                writePNG(cg, to: outputDirectory.appendingPathComponent("compare-\(slug).png"))

                let stats = luminanceStats(cg)
                let rgb = meanRGB(cg)
                emit(String(
                    format: "   compare/%-14@ %dx%d  mean %.3f  RGB %.3f %.3f %.3f",
                    slug as NSString, cg.width, cg.height,
                    stats.mean, rgb.r, rgb.g, rgb.b
                ))
            }

            // How long applying a preset takes, which is what the preset
            // browser's responsiveness comes down to. Presets vary
            // LuminanceSmoothing constantly, so this specifically checks that a
            // change in noise reduction no longer forces a re-demosaic.
            if let source = ImageSource(url: rawURL) {
                let renderer = PreviewRenderer()
                var settings = EditSettings()
                settings.isRawTemperature = true
                settings.colorNR = 25

                let coldClock = Date()
                _ = await renderer.preview(source: source, settings: settings)
                emit(String(format: "   apply/cold-open           %5dms",
                            Int(Date().timeIntervalSince(coldClock) * 1000)))

                let cases: [(String, EditSettings)] = [
                    ("preset, NR unchanged", {
                        var s = settings; s.contrast = 25; s.convertToGrayscale = true; return s
                    }()),
                    ("preset, NR changed", {
                        var s = settings; s.luminanceNR = 15; s.contrast = -50; return s
                    }()),
                    ("preset, WB + NR changed", {
                        var s = settings
                        s.luminanceNR = 22
                        s.whiteBalanceMode = .custom
                        s.temperature = 5736
                        s.tint = 16
                        return s
                    }()),
                ]

                for (label, applied) in cases {
                    let clock = Date()
                    _ = await renderer.preview(
                        source: source, settings: applied, allowReDecode: false
                    )
                    emit(String(format: "   apply/%-20@ %5dms", label as NSString,
                                Int(Date().timeIntervalSince(clock) * 1000)))
                }

                // And a browser thumbnail, which should now share one decode
                // across every preset rather than re-decoding per row.
                var thumbSettings = settings
                thumbSettings.luminanceNR = 15
                thumbSettings.whiteBalanceMode = .custom
                thumbSettings.temperature = 7200

                var firstThumb = 0.0
                var restTotal = 0.0
                for index in 0..<6 {
                    // Vary the settings the way scrolling through real presets
                    // would, to prove they share one decode.
                    thumbSettings.temperature = 5200 + Double(index) * 400
                    thumbSettings.luminanceNR = Double(index) * 5
                    let clock = Date()
                    _ = await renderer.thumbnail(source: source, settings: thumbSettings)
                    let elapsed = Date().timeIntervalSince(clock)
                    if index == 0 { firstThumb = elapsed } else { restTotal += elapsed }
                }
                emit(String(format: "   apply/thumbnail first     %5dms  (decodes once)",
                            Int(firstThumb * 1000)))
                emit(String(format: "   apply/thumbnail each after %4dms  (shared decode)",
                            Int(restTotal / 5 * 1000)))
            }

            emit("")
        }

        // MARK: Highlight artifact bisect
        //
        // Dark contour lines appear in the near-clipped sky. Renders the same
        // frame with each detail-stage suspect disabled so the culprit shows up
        // by elimination rather than by argument.

        if mode == "artifact",
           let dngURL = Bundle.main.url(forResource: "IMG20240926182032", withExtension: "dng"),
           let source = ImageSource(url: dngURL) {

            emit("Highlight artifact bisect (full resolution)")

            var base = EditSettings()
            base.isRawTemperature = true
            base.colorNR = 25
            if let kodachrome = DevPresets.named("Kodachrome") {
                base = kodachrome.settings(appliedTo: base)
                emit("   using preset: Kodachrome  sharpness=\(Int(base.sharpness)) radius=\(base.sharpenRadius) masking=\(Int(base.sharpenEdgeMasking)) clarity=\(Int(base.clarity))")
            }

            var cases: [(String, EditSettings)] = [("all", base)]

            var noSharpen = base
            noSharpen.sharpness = 0
            cases.append(("no-sharpen", noSharpen))

            var noClarity = base
            noClarity.clarity = 0
            noClarity.texture = 0
            cases.append(("no-clarity-texture", noClarity))

            var noDetail = base
            noDetail.sharpness = 0
            noDetail.clarity = 0
            noDetail.texture = 0
            noDetail.dehaze = 0
            cases.append(("no-detail-at-all", noDetail))

            var fullMask = base
            fullMask.sharpenEdgeMasking = 100
            cases.append(("sharpen-masked-100", fullMask))

            var noHSL = base
            noHSL.hueAdjustments = BandValues()
            noHSL.saturationAdjustments = BandValues()
            noHSL.luminanceAdjustments = BandValues()
            cases.append(("no-colour-mixer", noHSL))

            var noCurve = base
            noCurve.curveRGB = .linear
            noCurve.curveRed = .linear
            noCurve.curveGreen = .linear
            noCurve.curveBlue = .linear
            noCurve.parametricCurve = ParametricCurve()
            cases.append(("no-tone-curve", noCurve))

            var justDecode = EditSettings()
            justDecode.isRawTemperature = true
            justDecode.colorNR = 25
            cases.append(("decode-only", justDecode))

            for (label, settings) in cases {
                guard let decoded = source.makeBaseImage(
                    settings: settings, maxDimension: nil, draft: false
                ) else { continue }
                let processed = engine.process(decoded, settings: settings, isRaw: true)
                guard let cg = engine.makeCGImage(processed) else { continue }
                writePNG(cg, to: outputDirectory.appendingPathComponent("art-\(label).png"))
                emit("   rendered art-\(label).png")
            }

            emit("")
            emit(problems == 0 ? "No problems detected." : "\(problems) problem(s) detected.")
            emit("Total \(Int(Date().timeIntervalSince(started) * 1000))ms")
            try? Data(report.utf8).write(to: outputDirectory.appendingPathComponent("selfcheck.txt"))
            return
        }

        // MARK: Lightroom Classic comparison
        //
        // Renders the OPPO DNG at full resolution with the presets Henri also
        // rendered in Lightroom Classic, so the two can be diffed pixel for
        // pixel. Runs only in `lr` mode because it's full-size work.

        if mode == "lr",
           let dngURL = Bundle.main.url(forResource: "IMG20240926182032", withExtension: "dng"),
           let source = ImageSource(url: dngURL) {

            emit("Lightroom comparison renders (\(Int(source.nativeSize.width))x\(Int(source.nativeSize.height)))")

            func preset(_ fragment: String) -> Preset? { DevPresets.named(fragment) }

            var jobs: [(String, EditSettings)] = []

            var stock = EditSettings()
            stock.isRawTemperature = true
            stock.colorNR = 25
            jobs.append(("stock", stock))

            for (slug, fragment) in [("moody-01", "Moody 01"), ("aerochrome", "Aerochrome")] {
                guard let match = preset(fragment) else {
                    emit("   MISSING preset matching \(fragment)")
                    problems += 1
                    continue
                }
                jobs.append((slug, match.settings(appliedTo: stock)))
            }

            for (slug, settings) in jobs {
                let clock = Date()
                guard let decoded = source.makeBaseImage(
                    settings: settings, maxDimension: nil, draft: false
                ) else {
                    emit("   FAIL \(slug): decode returned nil")
                    problems += 1
                    continue
                }
                let processed = engine.process(decoded, settings: settings, isRaw: true)
                guard let cg = engine.makeCGImage(processed) else {
                    emit("   FAIL \(slug): render returned nil")
                    problems += 1
                    continue
                }
                writePNG(cg, to: outputDirectory.appendingPathComponent("lr-\(slug).png"))
                let rgb = meanRGB(cg)
                emit(String(
                    format: "   %-12@ %dx%d  RGB %.1f %.1f %.1f  %dms",
                    slug as NSString, cg.width, cg.height,
                    rgb.r * 255, rgb.g * 255, rgb.b * 255,
                    Int(Date().timeIntervalSince(clock) * 1000)
                ))
            }

            emit("")
            emit(problems == 0 ? "No problems detected." : "\(problems) problem(s) detected.")
            emit("Total \(Int(Date().timeIntervalSince(started) * 1000))ms")
            try? Data(report.utf8).write(to: outputDirectory.appendingPathComponent("selfcheck.txt"))
            return
        }

        // MARK: Bundled presets

        guard isFullRun else {
            emit("(fast run — heavy sections skipped; set PHOTO_EDITOR_SELFCHECK=full for all)")
            emit(problems == 0 ? "No problems detected." : "\(problems) problem(s) detected.")
            emit("Total \(Int(Date().timeIntervalSince(started) * 1000))ms")
            try? Data(report.utf8).write(to: outputDirectory.appendingPathComponent("selfcheck.txt"))
            return
        }

        // Pick a spread that exercises different parts of the pipeline.
        func preset(named fragment: String) -> Preset? { DevPresets.named(fragment) }

        var variants: [(String, EditSettings)] = [("00-neutral", EditSettings())]
        for fragment in ["CINEMATIC-001", "Kodachrome", "Aerochrome", "Moody"] {
            if let match = preset(named: fragment) {
                let safe = match.name.replacingOccurrences(of: "/", with: "-")
                variants.append(("preset-\(safe)", match.settings(appliedTo: EditSettings())))
            }
        }

        // Everything the custom kernels do, at once.
        var stress = EditSettings()
        stress.exposure = -0.75
        stress.contrast = 55
        stress.highlights = -90
        stress.shadows = 85
        stress.whites = 25
        stress.blacks = -30
        stress.clarity = 55
        stress.texture = 40
        stress.dehaze = 45
        stress.vibrance = 45
        stress.saturation = -10
        stress.sharpness = 90
        stress.grainAmount = 50
        stress.postCropVignetteAmount = -50
        stress.colorGrading.shadowHue = 215
        stress.colorGrading.shadowSat = 35
        stress.colorGrading.highlightHue = 45
        stress.colorGrading.highlightSat = 28
        stress.hueAdjustments[.orange] = -25
        stress.saturationAdjustments[.blue] = -40
        stress.luminanceAdjustments[.green] = 30
        stress.blueHue = -40
        stress.redHue = 25
        stress.greenSaturation = -20
        stress.shadowTint = -25
        stress.incrementalTemperature = 12
        variants.append(("zz-stress-all-kernels", stress))

        // IMG_1361.DNG is an iPhone 12 Pro ProRAW from the pixls.us sample
        // database — a different Apple sensor generation, so it checks the raw
        // path isn't tuned to one specific file.
        for name in ["IMG_4169.DNG", "IMG_1361.DNG", "IMG_4168.jpg", "IMG_4167.heic"] {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: stem, withExtension: ext) else {
                emit("MISSING SAMPLE: \(name)")
                problems += 1
                continue
            }
            guard let source = ImageSource(url: url) else {
                emit("FAILED TO OPEN: \(name)")
                problems += 1
                continue
            }

            emit("\(name)  raw=\(source.isRaw)  \(Int(source.nativeSize.width))×\(Int(source.nativeSize.height))  asShot=\(Int(source.asShotTemperature))K/\(Int(source.asShotTint))")

            for (label, base) in variants {
                var settings = base
                if source.isRaw, settings == EditSettings() { settings.colorNR = 25 }
                settings.isRawTemperature = source.isRaw

                let clock = Date()
                guard let decoded = source.makeBaseImage(
                    settings: settings, maxDimension: 1200, draft: true
                ) else {
                    emit("   FAIL \(label): decode returned nil")
                    problems += 1
                    continue
                }
                let decodeMS = Int(Date().timeIntervalSince(clock) * 1000)

                let renderClock = Date()
                let processed = engine.process(decoded, settings: settings, isRaw: source.isRaw)
                guard let cg = engine.makeCGImage(processed) else {
                    emit("   FAIL \(label): render returned nil")
                    problems += 1
                    continue
                }
                let renderMS = Int(Date().timeIntervalSince(renderClock) * 1000)

                let stats = luminanceStats(cg)
                var flag = ""
                if stats.mean < 0.015 { flag = "  <-- NEARLY BLACK"; problems += 1 }
                if stats.mean > 0.97 { flag = "  <-- NEARLY WHITE"; problems += 1 }
                if stats.max - stats.min < 0.05 { flag = "  <-- NO TONAL RANGE"; problems += 1 }

                writePNG(cg, to: outputDirectory.appendingPathComponent("\(stem)-\(label).png"))

                emit(String(
                    format: "   %-34@ decode %4dms  render %4dms  mean %.3f  min %.3f  max %.3f%@",
                    label as NSString, decodeMS, renderMS,
                    stats.mean, stats.min, stats.max, flag as NSString
                ))
            }
            emit("")
        }

        // MARK: Full-resolution export

        if let url = Bundle.main.url(forResource: "IMG_4169", withExtension: "DNG"),
           let source = ImageSource(url: url) {
            var settings = EditSettings()
            settings.isRawTemperature = true
            settings.colorNR = 25
            if let cinematic = preset(named: "CINEMATIC-001") {
                settings = cinematic.settings(appliedTo: settings)
            }

            let clock = Date()
            if let decoded = source.makeBaseImage(settings: settings, maxDimension: nil, draft: false) {
                let processed = engine.process(decoded, settings: settings, isRaw: true)
                if let data = engine.encode(
                    processed, as: .jpeg, quality: 0.92,
                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
                ) {
                    emit("Full-res export: \(data.count / 1024) KB in \(Int(Date().timeIntervalSince(clock) * 1000))ms")
                    try? data.write(to: outputDirectory.appendingPathComponent("fullres-export.jpg"))
                } else {
                    emit("FAIL: full-res encode returned nil")
                    problems += 1
                }
            } else {
                emit("FAIL: full-res decode returned nil")
                problems += 1
            }
        }

        // MARK: Stage bisect
        //
        // Renders one preset with each stage knocked out in turn and reports
        // the mean R/G/B, which localises a colour cast far faster than
        // staring at thumbnails.

        if let subject = preset(named: "Teals"),
           let url = Bundle.main.url(forResource: "IMG_4169", withExtension: "DNG"),
           let source = ImageSource(url: url) {

            var full = subject.settings(appliedTo: EditSettings())
            full.isRawTemperature = true

            var cases: [(String, EditSettings)] = [("full", full)]

            var noHSL = full
            noHSL.hueAdjustments = BandValues()
            noHSL.saturationAdjustments = BandValues()
            noHSL.luminanceAdjustments = BandValues()
            cases.append(("no colour mixer", noHSL))

            var noGrade = full
            noGrade.colorGrading = ColorGrading()
            cases.append(("no colour grading", noGrade))

            var noCalibration = full
            noCalibration.redHue = 0; noCalibration.greenHue = 0; noCalibration.blueHue = 0
            noCalibration.redSaturation = 0; noCalibration.greenSaturation = 0
            noCalibration.blueSaturation = 0; noCalibration.shadowTint = 0
            cases.append(("no calibration", noCalibration))

            var noWB = full
            noWB.incrementalTemperature = 0; noWB.incrementalTint = 0
            noWB.whiteBalanceMode = .asShot
            cases.append(("no white balance", noWB))

            var noCurve = full
            noCurve.curveRGB = .linear; noCurve.curveRed = .linear
            noCurve.curveGreen = .linear; noCurve.curveBlue = .linear
            noCurve.parametricCurve = ParametricCurve()
            cases.append(("no tone curve", noCurve))

            var noVibrance = full
            noVibrance.vibrance = 0; noVibrance.saturation = 0
            cases.append(("no vibrance/sat", noVibrance))

            var lightOnly = EditSettings()
            lightOnly.isRawTemperature = true
            lightOnly.exposure = full.exposure
            lightOnly.contrast = full.contrast
            lightOnly.highlights = full.highlights
            lightOnly.shadows = full.shadows
            lightOnly.whites = full.whites
            lightOnly.blacks = full.blacks
            cases.append(("light sliders only", lightOnly))

            cases.append(("neutral", { var s = EditSettings(); s.isRawTemperature = true; return s }()))

            emit("Stage bisect on Teals (mean R / G / B — a cast shows as a split)")
            for (label, settings) in cases {
                guard let decoded = source.makeBaseImage(
                    settings: settings, maxDimension: 700, draft: true
                ) else { continue }
                let processed = engine.process(decoded, settings: settings, isRaw: true)
                guard let cg = engine.makeCGImage(processed) else { continue }
                let rgb = meanRGB(cg)
                emit(String(format: "   %-22@ %.3f  %.3f  %.3f", label as NSString,
                            rgb.r, rgb.g, rgb.b))
                writePNG(cg, to: outputDirectory.appendingPathComponent("bisect-\(label).png"))
            }
            emit("")
        }

        // MARK: Interactive path
        //
        // The measurements above call the engine directly, which re-decodes on
        // every render. That is NOT what the app does — PreviewRenderer bakes
        // the decode into a texture once and reuses it. These numbers are the
        // ones that decide whether dragging a slider feels alive.

        emit("Interactive path (PreviewRenderer, \(Int(RenderEngine.previewLongEdge))px preview)")

        for name in ["IMG_4169.DNG", "IMG_4168.jpg", "IMG_4167.heic"] {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: stem, withExtension: ext),
                  let source = ImageSource(url: url)
            else { continue }

            let renderer = PreviewRenderer()
            var settings = EditSettings()
            settings.isRawTemperature = source.isRaw
            settings.colorNR = source.isRaw ? 25 : 0

            func measure(
                _ label: String,
                allowReDecode: Bool = false,
                _ mutate: (inout EditSettings) -> Void
            ) async {
                mutate(&settings)
                let clock = Date()
                let image = await renderer.preview(
                    source: source, settings: settings, allowReDecode: allowReDecode
                )
                let ms = Int(Date().timeIntervalSince(clock) * 1000)
                emit(String(format: "   %-30@ %5dms%@", label as NSString, ms,
                            (image == nil ? "  <-- nil" : "") as NSString))
                if image == nil { problems += 1 }
            }

            emit("  \(name)")
            await measure("cold (first render)", allowReDecode: true) { _ in }
            await measure("exposure drag") { $0.exposure = 0.35 }
            await measure("contrast drag") { $0.contrast = 25 }
            await measure("clarity + grain") { $0.clarity = 40; $0.grainAmount = 30 }
            await measure("relative WB drag") { $0.incrementalTemperature = 15 }
            if source.isRaw {
                await measure("absolute WB drag (adapted)") {
                    $0.whiteBalanceMode = .custom
                    $0.temperature = 6500
                }
                await measure("absolute WB settle (decode)", allowReDecode: true) { _ in }
                await measure("exposure after re-decode") { $0.exposure = 0.6 }
            }
            emit("")
        }

        emit(problems == 0 ? "No problems detected." : "\(problems) problem(s) detected.")
        emit("Total \(Int(Date().timeIntervalSince(started) * 1000))ms")

        try? Data(report.utf8).write(to: outputDirectory.appendingPathComponent("selfcheck.txt"))
    }

    // MARK: - Helpers

    private nonisolated static func luminanceStats(_ cg: CGImage) -> (mean: Double, min: Double, max: Double) {
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return (0, 0, 0) }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        var lo = 1.0
        var hi = 0.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let l = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                     + 0.0722 * Double(pixels[i + 2])) / 255.0
            total += l
            lo = Swift.min(lo, l)
            hi = Swift.max(hi, l)
        }
        return (total / Double(width * height), lo, hi)
    }

    private nonisolated static func meanRGB(_ cg: CGImage) -> (r: Double, g: Double, b: Double) {
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return (0, 0, 0) }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2])
        }
        let n = Double(width * height) * 255
        return (r / n, g / n, b / n)
    }

    private nonisolated static func writePNG(_ cg: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
    }
}

#endif
