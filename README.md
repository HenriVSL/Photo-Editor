# Photo Editor

A photo editor for iPhone and iPad that applies Adobe Camera Raw / Lightroom
style adjustments to Apple ProRAW and other DNG files, HEIC and JPEG. It
imports `.xmp` and legacy `.lrtemplate` presets that you supply and renders
them with its own Core Image and Metal pipeline.

## Features

| | |
|---|---|
| **Opens** | Apple ProRAW and other DNG raw files, HEIC and JPEG, from your photo library or the Files app |
| **Real RAW from Photos** | A built-in library browser reads the original DNG of ProRAW shots (the system picker only hands over a rendered JPEG), with RAW badges and a RAW-only filter |
| **Light** | Exposure, Contrast, Highlights, Shadows, Whites, Blacks |
| **Color** | Raw profile (Camera, matched to Lightroom's rendering, or a flat Neutral profile); white balance presets (As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom) with Temp and Tint; Vibrance and Saturation; Calibration (shadow tint and red/green/blue primary hue and saturation) |
| **Mixer** | Hue, saturation and luminance for eight colour bands, or Black & White conversion with a per-band grey mix |
| **Curve** | Point curves for RGB, red, green and blue, plus a parametric curve with adjustable region splits |
| **Grading** | Colour grading wheels for shadows, midtones, highlights and global, with blending and balance |
| **Effects** | Texture, Clarity, Dehaze; post-crop vignette (amount, midpoint, feather, roundness, style); grain (amount, size, roughness) |
| **Detail** | Lens vignetting, sharpening (amount, radius, detail, masking), luminance and colour noise reduction |
| **Presets** | Import Adobe `.xmp` presets and legacy Lightroom `.lrtemplate` files from Files, search and browse them by group with thumbnails rendered from the open photo, apply them with an Amount slider (0–100 %), save the current edit as a preset, and export any preset as an Adobe-compatible `.xmp` |
| **Honest about gaps** | Presets that depend on an Adobe camera profile that isn't included in the file get a visible warning, because that part of the look can't be reproduced |
| **Canvas** | Pinch to zoom, drag to pan, double-tap to toggle fit / 2×, press and hold to see the original |
| **Undo** | Undo and redo for every change (a slider drag is one step), and Reset All Adjustments |
| **Export** | Full-resolution render to JPEG, HEIF, PNG or TIFF, with a quality setting and sRGB or Display P3 colour. Share or save to Photos |

The app ships with no presets. Everything in the preset list is imported or
created by you.

## How it works

- **Decoding**: raw files go through `CIRAWFilter` with Apple's own look
  turned off (no boost, local tone mapping or sharpening), which gives the
  same linear, scene-referred starting point Camera Raw works from. ProRAW keeps
  its embedded Apple profile; other raws get a measured base curve so they start
  close to Lightroom's default rendering. HEIC and JPEG skip the raw step.
- **Adjustments**: `EditSettings` mirrors Adobe's develop parameters one to
  one, so a parsed preset maps straight onto it and can be written back out as
  `.xmp`. Both the current (Process Version 2012) and the older key sets are
  understood.
- **Rendering**: the adjustments run as custom Core Image kernels written in
  Metal (`Render/AdobeKernels.ci.metal`, compiled with `-fcikernel`). The tone
  curve stack (parametric then point curves) is baked into a lookup table per
  channel. The preview renders in draft mode at a reduced size; export renders
  at full resolution.
- **Preset Amount**: blends in parameter space, as Lightroom does, rather than
  cross-fading two images, so a half-strength preset still combines correctly
  with edits made afterwards.
- **Storage**: presets are saved as files in the app's Application Support
  folder.

## Requirements

- iOS 26.2 or later
- iPhone or iPad
- To build: Xcode 26.2 or later

The app asks for photo library access (`NSPhotoLibraryUsageDescription`) to
open original RAW files from your library and add-only access
(`NSPhotoLibraryAddUsageDescription`) to save exports. Without library access
you can still open files from the Files app.

## Install

1. Download the unsigned `.ipa` from the
   [latest release](https://github.com/HenriVSL/Photo-Editor/releases/latest).
2. Sideload it with a tool that re-signs it with your own Apple ID, such as
   [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
   [Sideloadly](https://sideloadly.io).

With a free Apple ID the app has to be re-signed every 7 days. On iOS 16 and
later you may also need to turn on Developer Mode (Settings > Privacy &
Security).

## Build from source

1. Open `Photo Editor.xcodeproj` in Xcode.
2. Select the **Photo Editor** target and choose your team under
   **Signing & Capabilities**. If the bundle identifier is already taken, change
   it to something unique.
3. Build and run.

`DevSelfCheck.swift`, `DevColorCheck.swift` and `DevPresets.swift` are
development-only checks compiled into Debug builds. They run only when launched
with the `PHOTO_EDITOR_SELFCHECK` environment variable and expect sample files
that are not part of this repository.

## Third-party components

None. The app uses only Apple frameworks (SwiftUI, Core Image, Metal, PhotoKit).

Adobe, Camera Raw and Lightroom are trademarks of Adobe. This project is not
affiliated with or endorsed by Adobe; the names are used only to describe the
preset formats the app reads and writes.

## License

MIT, see [LICENSE](LICENSE).
