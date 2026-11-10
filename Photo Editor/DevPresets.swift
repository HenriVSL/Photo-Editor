//
//  DevPresets.swift
//  Photo Editor
//
//  DEVELOPMENT ONLY.
//
//  The handful of presets the self-check renders, loaded from the .xmp files
//  in `DevSamples/`. The app itself ships no presets — everything the user
//  sees is imported by them.
//

#if DEBUG

import Foundation

enum DevPresets {

    /// First preset whose name contains `fragment`, parsed on demand.
    static func named(_ fragment: String) -> Preset? {
        for url in Bundle.main.urls(forResourcesWithExtension: "xmp", subdirectory: nil) ?? [] {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? XMPPresetParser.parse(data: data)
            else { continue }

            let name = parsed.name ?? url.deletingPathExtension().lastPathComponent
            guard name.localizedCaseInsensitiveContains(fragment)
                    || url.lastPathComponent.localizedCaseInsensitiveContains(fragment)
            else { continue }

            return Preset(
                name: name,
                group: parsed.group,
                settings: parsed.settings,
                origin: .xmp,
                sourceUUID: parsed.uuid,
                rawValues: parsed.raw,
                missingLook: parsed.missingLook
            )
        }
        return nil
    }
}

#endif
