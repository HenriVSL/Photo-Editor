//
//  CIKernelLibrary.swift
//  Photo Editor
//
//  Loads the compiled Metal kernels once and hands them to the renderer.
//
//  The kernels live in the target's default.metallib, built with -fcikernel.
//  If loading ever fails the renderer degrades to a pass-through rather than
//  trapping, so a shader problem shows up as an unprocessed image and a log
//  line instead of a crash.
//

import CoreImage
import Foundation
import os

nonisolated final class CIKernelLibrary: @unchecked Sendable {

    static let shared = CIKernelLibrary()

    private static let log = Logger(subsystem: "henril.Photo-Editor", category: "Render")

    let wbExposure: CIColorKernel?
    let basicTone: CIColorKernel?
    let colorMixer: CIColorKernel?
    let colorGrade: CIColorKernel?
    let clarityTexture: CIColorKernel?
    let dehaze: CIColorKernel?
    let sharpen: CIColorKernel?
    let colorNoiseReduction: CIColorKernel?
    let darkChannel: CIColorKernel?
    let postCropVignette: CIKernel?
    let filmGrain: CIKernel?

    /// True when every kernel compiled and loaded.
    let isComplete: Bool

    private init() {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url)
        else {
            Self.log.error("default.metallib not found — adjustments will be skipped")
            wbExposure = nil
            basicTone = nil
            colorMixer = nil
            colorGrade = nil
            clarityTexture = nil
            dehaze = nil
            sharpen = nil
            colorNoiseReduction = nil
            darkChannel = nil
            postCropVignette = nil
            filmGrain = nil
            isComplete = false
            return
        }

        func colorKernel(_ name: String) -> CIColorKernel? {
            do {
                return try CIColorKernel(functionName: name, fromMetalLibraryData: data)
            } catch {
                Self.log.error("Failed to load colour kernel \(name): \(error.localizedDescription)")
                return nil
            }
        }

        func generalKernel(_ name: String) -> CIKernel? {
            do {
                return try CIKernel(functionName: name, fromMetalLibraryData: data)
            } catch {
                Self.log.error("Failed to load kernel \(name): \(error.localizedDescription)")
                return nil
            }
        }

        wbExposure = colorKernel("wbExposure")
        basicTone = colorKernel("basicTone")
        colorMixer = colorKernel("colorMixer")
        colorGrade = colorKernel("colorGrade")
        clarityTexture = colorKernel("clarityTexture")
        dehaze = colorKernel("dehaze")
        sharpen = colorKernel("sharpen")
        colorNoiseReduction = colorKernel("colorNoiseReduction")
        darkChannel = colorKernel("darkChannel")
        postCropVignette = generalKernel("postCropVignette")
        filmGrain = generalKernel("filmGrain")

        isComplete = wbExposure != nil && basicTone != nil && colorMixer != nil
            && colorGrade != nil && clarityTexture != nil && dehaze != nil
            && sharpen != nil && colorNoiseReduction != nil && darkChannel != nil
            && postCropVignette != nil && filmGrain != nil

        if isComplete {
            Self.log.info("Loaded all Core Image kernels")
        }
    }
}
