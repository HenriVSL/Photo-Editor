//
//  EditorModel.swift
//  Photo Editor
//
//  Editing state for the open photo: the parameter set, the rendered preview,
//  undo history, and preset application.
//

import CoreGraphics
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorModel {

    // MARK: Image

    private(set) var source: ImageSource?
    private(set) var previewImage: CGImage?
    private(set) var originalImage: CGImage?

    var displayName: String { source?.displayName ?? "No photo" }
    var hasImage: Bool { source != nil }

    // MARK: Adjustments

    private(set) var settings = EditSettings()

    /// Shown while dragging the before/after control.
    var isShowingOriginal = false

    // MARK: Preset state

    private(set) var appliedPreset: Preset?
    /// Strength of the applied preset, 0...1. Change it through
    /// `setPresetAmount(_:)`, which re-blends in parameter space.
    private(set) var presetAmount: Double = 1
    private var settingsBeforePreset: EditSettings?
    private var presetTarget: EditSettings?

    // MARK: Status

    private(set) var isLoading = false
    private(set) var isRendering = false

    /// One channel for anything that needs telling to the user. A single
    /// alert driven by this avoids stacking `.alert` modifiers on one view,
    /// where the later one wins and the earlier silently never presents.
    var notice: Notice?

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String

        static func problem(_ message: String) -> Notice {
            Notice(title: "Something Went Wrong", message: message)
        }
    }

    // MARK: History

    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Compared against the state the photo opened in, not against a blank
    /// EditSettings — a raw file starts with its own as-shot white balance.
    var isModified: Bool { settings != openingSettings }
    private var openingSettings = EditSettings()

    // MARK: Rendering

    private let renderer = PreviewRenderer()

    /// Thumbnails get their own renderer so the preset browser can't block the
    /// canvas. Both are actors, so sharing one would mean tapping a preset
    /// queues behind every thumbnail still in flight — which is exactly what
    /// made applying a preset feel slow.
    private let thumbnailRenderer = PreviewRenderer()

    private var renderTask: Task<Void, Never>?
    private var thumbnailCache: [UUID: CGImage] = [:]

    // MARK: - Opening images

    func open(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Copy into our own container: the picked URL's access ends when this
        // function returns, but the renderer needs the file for the whole
        // editing session.
        guard let local = copyIntoWorkingDirectory(url) else {
            notice = .problem("Couldn't read \(url.lastPathComponent).")
            return
        }
        guard let source = ImageSource(url: local) else {
            notice = .problem("\(url.lastPathComponent) isn't an image this app can open.")
            return
        }
        await adopt(source)
    }

    func open(data: Data, name: String, typeIdentifier: String?) async {
        guard let source = ImageSource(data: data, name: name, typeIdentifier: typeIdentifier) else {
            notice = .problem("That photo couldn't be decoded.")
            return
        }
        await adopt(source)
    }

    private func adopt(_ source: ImageSource) async {
        isLoading = true
        defer { isLoading = false }

        renderTask?.cancel()
        await renderer.invalidate()
        await thumbnailRenderer.invalidate()

        self.source = source
        settings = Self.openingSettings(for: source)
        openingSettings = settings

        undoStack.removeAll()
        redoStack.removeAll()
        thumbnailCache.removeAll()
        clearPresetState()

        originalImage = await renderer.original(source: source, settings: settings)
        previewImage = originalImage
        render()
    }

    private func copyIntoWorkingDirectory(_ url: URL) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - Editing

    /// A binding for one numeric parameter, for use by the slider rows.
    func binding(_ keyPath: WritableKeyPath<EditSettings, Double>) -> Binding<Double> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.render() }
        )
    }

    func binding(_ keyPath: WritableKeyPath<EditSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                self.recordUndo()
                self.settings[keyPath: keyPath] = newValue
                self.render()
            }
        )
    }

    /// Temperature and tint need to flip the mode off As Shot, otherwise
    /// dragging them would have no effect on a raw file.
    func whiteBalanceBinding(_ keyPath: WritableKeyPath<EditSettings, Double>) -> Binding<Double> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: {
                self.settings[keyPath: keyPath] = $0
                if self.settings.whiteBalanceMode == .asShot {
                    self.settings.whiteBalanceMode = .custom
                }
                self.render()
            }
        )
    }

    /// Per-band bindings for the colour mixer panels.
    func bandBinding(
        _ keyPath: WritableKeyPath<EditSettings, BandValues>,
        _ band: ColorBand
    ) -> Binding<Double> {
        Binding(
            get: { self.settings[keyPath: keyPath][band] },
            set: { self.settings[keyPath: keyPath][band] = $0; self.render() }
        )
    }

    func update<Value>(_ keyPath: WritableKeyPath<EditSettings, Value>, to value: Value) {
        recordUndo()
        settings[keyPath: keyPath] = value
        render()
    }

    func setCurve(_ keyPath: WritableKeyPath<EditSettings, PointCurve>, to curve: PointCurve) {
        settings[keyPath: keyPath] = curve
        render()
    }

    func reset(_ keyPath: WritableKeyPath<EditSettings, Double>, to neutral: Double) {
        recordUndo()
        settings[keyPath: keyPath] = neutral
        render()
    }

    func resetAll() {
        recordUndo()
        settings = openingSettings
        clearPresetState()
        render()
    }

    /// The state a freshly opened photo starts in.
    private static func openingSettings(for source: ImageSource) -> EditSettings {
        var settings = EditSettings()
        // Adobe's own raw default: a little colour noise reduction, nothing else.
        settings.colorNR = source.isRaw ? 25 : 0
        settings.isRawTemperature = source.isRaw
        if source.isRaw {
            // Seed the Temp and Tint sliders with the camera's own white point
            // so they read something meaningful before they're touched. The
            // mode stays As Shot, so nothing is applied until one moves.
            settings.temperature = source.asShotTemperature
            settings.tint = source.asShotTint
        }
        return settings
    }

    // MARK: - Undo

    /// Call at the start of a gesture so the whole drag is one undo step.
    func beginInteraction() {
        recordUndo()
    }

    private func recordUndo() {
        // Collapse no-op edits so undo doesn't fill up with duplicates.
        if undoStack.last == settings { return }
        undoStack.append(settings)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        settings = previous
        clearPresetState()
        render()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        settings = next
        clearPresetState()
        render()
    }

    // MARK: - Presets

    func apply(_ preset: Preset) {
        recordUndo()
        let base = settings
        let target = preset.settings(appliedTo: base)

        settingsBeforePreset = base
        presetTarget = target
        appliedPreset = preset
        presetAmount = 1

        settings = target
        render()
    }

    /// Re-dials the applied preset between the edit you had and what the
    /// preset asks for. Blending happens in parameter space, so adjustments
    /// made afterwards still compose correctly.
    func setPresetAmount(_ amount: Double) {
        presetAmount = amount.clamped(to: 0...1)
        guard let before = settingsBeforePreset, let target = presetTarget else { return }
        settings = before.interpolated(towards: target, amount: presetAmount)
        render()
    }

    /// Forgets which preset produced the current state — used when the edit
    /// moves on so the Amount slider doesn't snap things back unexpectedly.
    private func clearPresetState() {
        appliedPreset = nil
        settingsBeforePreset = nil
        presetTarget = nil
        presetAmount = 1
    }

    /// Captures the current adjustments as a new preset.
    func makePreset(named name: String, group: String?) -> Preset {
        Preset(
            name: name,
            group: group,
            settings: settings,
            origin: .user
        )
    }

    // MARK: - Rendering

    /// Renders the preview, then refines it once the edit settles.
    ///
    /// The first pass never re-decodes: on a raw file a white balance change is
    /// served by adapting the already-demosaiced pixels, which keeps a Temp
    /// drag responsive instead of costing a second per frame. When the edit has
    /// been still for a moment, a second pass re-decodes so the result is the
    /// camera-referred one again.
    func render() {
        guard let source else { return }
        renderTask?.cancel()

        let settings = settings
        renderTask = Task { [weak self] in
            guard let self else { return }
            // Coalesce the flood of updates a slider drag produces.
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }

            self.isRendering = true
            let quick = await self.renderer.preview(
                source: source, settings: settings, allowReDecode: false
            )
            guard !Task.isCancelled else { return }
            if let quick { self.previewImage = quick }
            self.isRendering = false

            // Settle, then take the accurate path if nothing else has changed.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            let refined = await self.renderer.preview(
                source: source, settings: settings, allowReDecode: true
            )
            guard !Task.isCancelled else { return }
            if let refined { self.previewImage = refined }
        }
    }

    /// Renders a preset onto the open photo for the browser's thumbnails.
    ///
    /// Results are cached per preset: with several hundred presets in the list
    /// a re-render on every scroll would be unusable, and the answer only
    /// changes when the open photo does.
    func thumbnail(for preset: Preset) async -> CGImage? {
        guard let source else { return nil }
        if let cached = thumbnailCache[preset.id] { return cached }

        let target = preset.settings(appliedTo: EditSettings())
        let image = await thumbnailRenderer.thumbnail(source: source, settings: target)
        if let image { thumbnailCache[preset.id] = image }
        return image
    }

    // MARK: - Export

    func exportData(
        format: ExportFormat,
        quality: Double,
        colorSpace: CGColorSpace
    ) async -> Data? {
        guard let source else { return nil }
        return await renderer.export(
            source: source,
            settings: settings,
            format: format,
            quality: quality,
            colorSpace: colorSpace
        )
    }

    /// Writes an export to a temporary file for the share sheet.
    func exportFile(
        format: ExportFormat,
        quality: Double,
        colorSpace: CGColorSpace
    ) async -> URL? {
        guard let data = await exportData(format: format, quality: quality, colorSpace: colorSpace)
        else { return nil }

        let base = (source?.displayName as NSString?)?.deletingPathExtension ?? "Edited"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-edited.\(format.fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            notice = .problem("Couldn't write the exported file.")
            return nil
        }
    }
}
