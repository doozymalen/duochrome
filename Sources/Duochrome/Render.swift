import CoreImage
import Metal

/// GPU resources shared across the app. CIContext is expensive to create and thread-safe.
enum Render {
    static let device = MTLCreateSystemDefaultDevice()!
    static let queue = device.makeCommandQueue()!
    static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!
    /// Working space is linear Rec.2020 half-float. Covers nearly the camera gamut.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let context = CIContext(mtlCommandQueue: queue, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
    ])
    /// For full-size export only: keeps no intermediates (45 MP intermediates piled up in the cache and held several GB)
    static let exportContext = CIContext(mtlCommandQueue: device.makeCommandQueue()!, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// Paints areas clipped on the display. Highlights red, shadows blue.
    /// Soft proof: converts to sRGB, clamps to 0–1, and back. With `warn`, clipped pixels (out of gamut) are painted gray.
    static func softProof(_ img: CIImage, warn: Bool) -> CIImage {
        // Use the chosen output profile if set (PhotoWorkflow.swift)
        if ProofProfile.current != nil, let p = ProofProfile.apply(img, warn: warn) { return p }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let inS = img.matchedFromWorkingSpace(to: srgb) else { return img }
        let clamped = inS.applyingFilter("CIColorClamp")
        guard let back = clamped.matchedToWorkingSpace(from: srgb) else { return img }
        guard warn else { return back }
        return GPU.run("gamut_warn", [inS, clamped, back], extent: img.extent)
    }

    static func clippingOverlay(_ img: CIImage) -> CIImage {
        // Judge in display color space values. Working-space values above 1 may not clip on the display.
        let display = img.matchedFromWorkingSpace(to: displaySpace) ?? img
        let maxC = display.applyingFilter("CIMaximumComponent")
        let hi = maxC.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.998])
        let lo = maxC.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.002])
            .applyingFilter("CIColorInvert")
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: img.extent)
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.4, blue: 1)).cropped(to: img.extent)
        let withHigh = red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: hi])
        return blue.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: withHigh, kCIInputMaskImageKey: lo])
    }
}
