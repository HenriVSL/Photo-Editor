//
//  PresetStore.swift
//  Photo Editor
//
//  Persists presets to Application Support and handles importing Adobe files
//  picked from Files / iCloud Drive.
//

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PresetStore {

    /// Presets the user imported or created, persisted to disk.
    private(set) var storedPresets: [Preset] = []
    private(set) var lastImportSummary: ImportSummary?

    var presets: [Preset] { storedPresets }

    struct ImportSummary: Equatable {
        var imported: [String] = []
        var updated: [String] = []
        var failures: [(name: String, reason: String)] = []

        var isEmpty: Bool { imported.isEmpty && updated.isEmpty && failures.isEmpty }

        var message: String {
            var parts: [String] = []
            if !imported.isEmpty { parts.append("\(imported.count) imported") }
            if !updated.isEmpty { parts.append("\(updated.count) updated") }
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            return parts.joined(separator: ", ")
        }

        static func == (lhs: ImportSummary, rhs: ImportSummary) -> Bool {
            lhs.imported == rhs.imported
                && lhs.updated == rhs.updated
                && lhs.failures.map(\.name) == rhs.failures.map(\.name)
        }
    }

    /// Content types the document picker should offer.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let xmp = UTType(filenameExtension: "xmp") { types.append(xmp) }
        if let lr = UTType(filenameExtension: "lrtemplate") { types.append(lr) }
        types.append(.data)  // .lrtemplate has no registered type on most systems
        return types
    }

    private let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        storedPresets = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Preset.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func write(_ preset: Preset) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        try data.write(to: fileURL(for: preset), options: .atomic)
    }

    private func fileURL(for preset: Preset) -> URL {
        directory.appendingPathComponent("\(preset.id.uuidString).json")
    }

    // MARK: - Mutation

    func save(_ preset: Preset) {
        if let index = storedPresets.firstIndex(where: { $0.id == preset.id }) {
            storedPresets[index] = preset
        } else {
            storedPresets.append(preset)
        }
        storedPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try? write(preset)
    }

    func delete(_ preset: Preset) {
        storedPresets.removeAll { $0.id == preset.id }
        try? FileManager.default.removeItem(at: fileURL(for: preset))
    }

    func rename(_ preset: Preset, to name: String) {
        guard var updated = storedPresets.first(where: { $0.id == preset.id }) else { return }
        updated.name = name
        save(updated)
    }

    /// Groups for the browser, in a stable order with user presets first.
    var groupedPresets: [(group: String, presets: [Preset])] {
        let grouped = Dictionary(grouping: presets, by: \.effectiveGroup)
        return grouped
            .map { (group: $0.key, presets: $0.value) }
            .map { (group: $0.group, presets: $0.presets.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }) }
            .sorted { lhs, rhs in
                if lhs.group == "My Presets" { return true }
                if rhs.group == "My Presets" { return false }
                return lhs.group.localizedStandardCompare(rhs.group) == .orderedAscending
            }
    }

    // MARK: - Import

    @discardableResult
    func importPresets(from urls: [URL]) -> ImportSummary {
        var summary = ImportSummary()

        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            // Files delivers security-scoped URLs; the app can't read them
            // outside a start/stop pair.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let preset = try makePreset(from: url)
                if let existing = storedPresets.first(where: {
                    $0.sourceUUID != nil && $0.sourceUUID == preset.sourceUUID
                }) {
                    var merged = preset
                    merged.id = existing.id
                    save(merged)
                    summary.updated.append(preset.name)
                } else {
                    save(preset)
                    summary.imported.append(preset.name)
                }
            } catch {
                summary.failures.append((name: name, reason: error.localizedDescription))
            }
        }

        lastImportSummary = summary
        return summary
    }

    private func makePreset(from url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        let fallbackName = url.deletingPathExtension().lastPathComponent

        if url.pathExtension.lowercased() == "lrtemplate" {
            let parsed = try LRTemplateParser.parse(data: data)
            return Preset(
                name: parsed.title ?? parsed.internalName ?? fallbackName,
                group: nil,
                settings: parsed.settings,
                origin: .lrtemplate,
                sourceUUID: parsed.uuid,
                rawValues: parsed.raw
            )
        }

        // Anything else is treated as XMP; if it doesn't parse as XML, fall
        // back to the Lua reader in case the extension was simply wrong.
        do {
            let parsed = try XMPPresetParser.parse(data: data)
            return Preset(
                name: parsed.name ?? fallbackName,
                group: parsed.group,
                notes: parsed.presetDescription,
                settings: parsed.settings,
                origin: .xmp,
                sourceUUID: parsed.uuid,
                rawValues: parsed.raw,
                missingLook: parsed.missingLook
            )
        } catch {
            guard let parsed = try? LRTemplateParser.parse(data: data) else { throw error }
            return Preset(
                name: parsed.title ?? fallbackName,
                settings: parsed.settings,
                origin: .lrtemplate,
                sourceUUID: parsed.uuid,
                rawValues: parsed.raw
            )
        }
    }

    // MARK: - Export

    /// Writes the preset as an Adobe-compatible .xmp in a temporary location
    /// suitable for the share sheet.
    func exportURL(for preset: Preset) throws -> URL {
        let safeName = preset.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).xmp")
        try XMPPresetWriter.data(for: preset).write(to: url, options: .atomic)
        return url
    }
}
