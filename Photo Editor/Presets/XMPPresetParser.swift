//
//  XMPPresetParser.swift
//  Photo Editor
//
//  Reads Adobe Camera Raw / Lightroom .xmp presets and develop sidecars.
//
//  Adobe writes settings two different ways and both turn up in the wild:
//  as attributes on `rdf:Description` (current Camera Raw) or as child
//  elements (Camera Raw 4/5 era). Structured values — tone curves and
//  localised names — always live in `rdf:Seq` / `rdf:Alt` containers.
//  This parser handles all of it.
//

import Foundation

struct ParsedXMPPreset {
    var name: String?
    var group: String?
    var presetDescription: String?
    var uuid: String?
    var settings: EditSettings
    var raw: RawPresetValues
    /// Name of an Adobe Creative Profile the preset relies on but doesn't
    /// contain. See `Preset.missingLook`.
    var missingLook: String?
}

enum XMPPresetParser {

    static let cameraRawNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    enum ParseError: LocalizedError {
        case malformedXML(String)
        case noSettingsFound

        var errorDescription: String? {
            switch self {
            case .malformedXML(let detail): "The XMP file couldn't be read: \(detail)"
            case .noSettingsFound: "No Camera Raw settings were found in this file."
            }
        }
    }

    static func parse(data: Data) throws -> ParsedXMPPreset {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "unknown error"
            throw ParseError.malformedXML(detail)
        }

        let raw = delegate.values
        guard !raw.scalars.isEmpty || !raw.sequences.isEmpty else {
            throw ParseError.noSettingsFound
        }

        return ParsedXMPPreset(
            name: raw.string("Name"),
            group: raw.string("Group"),
            presetDescription: raw.string("Description"),
            uuid: raw.scalars["UUID"],
            settings: PresetMapper.settings(from: raw),
            raw: raw,
            missingLook: delegate.missingLook
        )
    }

    static func parse(url: URL) throws -> ParsedXMPPreset {
        try parse(data: Data(contentsOf: url))
    }

    // MARK: - XMLParser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var values = RawPresetValues()

        /// Set when the file references an Adobe profile whose lookup table
        /// it doesn't carry.
        var missingLook: String?
        private var insideLook = false
        private var lookIsStubbed = false
        private var lookName: String?

        /// Prefixes bound to the Camera Raw namespace. Nearly always `crs`,
        /// but the spec allows any prefix so we resolve it properly.
        private var crsPrefixes: Set<String> = ["crs"]
        private var stack: [String] = []
        private var text = ""
        private var hasChildren: [Bool] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            // Pick up namespace bindings before reading any attribute.
            for (key, value) in attributeDict where key.hasPrefix("xmlns:") {
                if value == XMPPresetParser.cameraRawNamespace {
                    crsPrefixes.insert(String(key.dropFirst("xmlns:".count)))
                }
            }

            // A `crs:Look` block carries its own Name / Amount / UUID /
            // Copyright, which must not overwrite the preset's own keys of the
            // same name. It's a standard XMP struct, so those attributes sit on
            // a nested `rdf:Description` rather than on `crs:Look` itself.
            if crsLocalName(elementName) == "Look" { insideLook = true }

            if insideLook {
                for (key, value) in attributeDict {
                    switch crsLocalName(key) {
                    case "Stubbed": lookIsStubbed = value.lowercased() == "true"
                    case "Name": lookName = value
                    default: break
                    }
                }
            } else {
                for (key, value) in attributeDict {
                    guard let local = crsLocalName(key) else { continue }
                    values.scalars[local] = value
                }
            }

            if !hasChildren.isEmpty { hasChildren[hasChildren.count - 1] = true }
            stack.append(crsLocalName(elementName) ?? localName(elementName))
            hasChildren.append(false)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let hadChildren = hasChildren.popLast() ?? false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let local = localName(elementName)

            if local == "li" {
                // Stack is [..., <crs key>, Seq|Alt, li].
                if !insideLook, stack.count >= 3 {
                    let containerKey = stack[stack.count - 3]
                    values.sequences[containerKey, default: []].append(trimmed)
                }
            } else if !insideLook, !hadChildren, !trimmed.isEmpty, let key = crsLocalName(elementName) {
                values.scalars[key] = trimmed
            }

            if crsLocalName(elementName) == "Look" {
                insideLook = false
                // Only report a Look we genuinely can't reproduce. One with an
                // embedded table would be applicable; a stubbed one is a bare
                // reference to a profile that ships inside Lightroom.
                if lookIsStubbed { missingLook = lookName ?? "" }
                lookIsStubbed = false
                lookName = nil
            }
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }

        /// Local name if the qualified name sits in the Camera Raw namespace.
        private func crsLocalName(_ qualified: String) -> String? {
            guard let colon = qualified.firstIndex(of: ":") else { return nil }
            let prefix = String(qualified[qualified.startIndex..<colon])
            guard crsPrefixes.contains(prefix) else { return nil }
            return String(qualified[qualified.index(after: colon)...])
        }

        private func localName(_ qualified: String) -> String {
            guard let colon = qualified.firstIndex(of: ":") else { return qualified }
            return String(qualified[qualified.index(after: colon)...])
        }
    }
}
