//
//  Preset.swift
//  Photo Editor
//

import Foundation

struct Preset: Identifiable, Codable, Equatable, Hashable {

    enum Origin: String, Codable, Sendable {
        case xmp            // Adobe Camera Raw / Lightroom .xmp
        case lrtemplate     // Legacy Lightroom .lrtemplate
        case user           // Created in this app

        var displayName: String {
            switch self {
            case .xmp: "Camera Raw"
            case .lrtemplate: "Lightroom (legacy)"
            case .user: "Created here"
            }
        }
    }

    var id: UUID
    var name: String
    var group: String?
    var notes: String?
    var settings: EditSettings
    var origin: Origin
    var importedAt: Date

    /// Adobe's own preset identifier, kept so re-importing the same file
    /// updates rather than duplicates.
    var sourceUUID: String?

    /// The keys the file actually declared. Present for imported presets so
    /// they can be merged onto the current edit; `nil` for presets created
    /// here, which always describe a complete state.
    var rawValues: RawPresetValues?

    /// Name of an Adobe Creative Profile this preset needs but doesn't
    /// include. Adobe ships those lookup tables inside Lightroom and the
    /// preset only references them by name and UUID (`crs:Stubbed="true"`), so
    /// no third-party app can reproduce that part of the look.
    var missingLook: String?

    init(
        id: UUID = UUID(),
        name: String,
        group: String? = nil,
        notes: String? = nil,
        settings: EditSettings,
        origin: Origin,
        importedAt: Date = Date(),
        sourceUUID: String? = nil,
        rawValues: RawPresetValues? = nil,
        missingLook: String? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.notes = notes
        self.settings = settings
        self.origin = origin
        self.importedAt = importedAt
        self.sourceUUID = sourceUUID
        self.rawValues = rawValues
        self.missingLook = missingLook
    }

    /// The settings this preset produces when applied on top of `current`.
    func settings(appliedTo current: EditSettings) -> EditSettings {
        guard let rawValues else { return settings }
        return PresetMapper.settings(from: rawValues, base: current)
    }

    /// Group shown in the browser when the preset didn't declare one.
    var effectiveGroup: String {
        if let group, !group.trimmingCharacters(in: .whitespaces).isEmpty { return group }
        switch origin {
        case .user: return "My Presets"
        case .xmp, .lrtemplate: return "Imported"
        }
    }

    /// Set when part of this preset can't be applied. Adobe's Creative
    /// Profiles ship inside Lightroom; a preset only references one by name and
    /// UUID, so the lookup table simply isn't in the file for anyone else to
    /// read. Everything the preset *does* contain still applies.
    var missingLookWarning: String? {
        guard let missingLook else { return nil }
        let name = missingLook.trimmingCharacters(in: .whitespaces)
        return name.isEmpty
            ? "Part of this preset needs an Adobe profile that isn't included in the file, so the look won't fully match Lightroom."
            : "Part of this preset needs Adobe's “\(name)” profile, which isn't included in the file, so the look won't fully match Lightroom."
    }

    /// A short summary of what the preset actually changes, for the list row.
    var summary: String {
        var parts: [String] = []
        if settings.convertToGrayscale { parts.append("B&W") }
        if settings.exposure != 0 { parts.append(String(format: "Exp %+.2f", settings.exposure)) }
        if settings.contrast != 0 { parts.append("Contrast \(Int(settings.contrast))") }
        if !settings.curveRGB.isLinear { parts.append("Curve") }
        if !settings.colorGrading.isNeutral { parts.append("Grade") }
        if settings.dehaze != 0 { parts.append("Dehaze \(Int(settings.dehaze))") }
        if settings.grainAmount != 0 { parts.append("Grain") }
        return parts.isEmpty ? "No adjustments" : parts.prefix(4).joined(separator: " · ")
    }
}
