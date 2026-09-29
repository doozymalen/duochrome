import Foundation

/// Slider response multipliers. Applied to slider values when rendering (stored values and displayed numbers unchanged).
///
/// All 1 for now (no multiplier).
enum SliderResponse {
    static var exposure: Float = 1
    static var contrast: Float = 1
    static var brightness: Float = 1
    static var saturation: Float = 1
    static var highlight: Float = 1
    static var shadow: Float = 1
    static var white: Float = 1
    static var black: Float = 1
    static var clarity: Float = 1
    static var structure: Float = 1
    static var dehaze: Float = 1

    static let keys: [(String, WritableKeyPath<DevelopSettings, Float>)] = [
        ("exposure", \.exposure), ("contrast", \.contrast), ("brightness", \.brightness), ("saturation", \.saturation),
        ("highlight", \.highlightTone), ("shadow", \.shadow), ("white", \.white), ("black", \.black),
        ("clarity", \.clarity), ("structure", \.structure), ("dehaze", \.dehaze),
    ]

    static func factor(_ name: String) -> Float {
        switch name {
        case "exposure": exposure
        case "contrast": contrast
        case "brightness": brightness
        case "saturation": saturation
        case "highlight": highlight
        case "shadow": shadow
        case "white": white
        case "black": black
        case "clarity": clarity
        case "structure": structure
        case "dehaze": dehaze
        default: 1
        }
    }

    static func set(_ name: String, _ v: Float) {
        switch name {
        case "exposure": exposure = v
        case "contrast": contrast = v
        case "brightness": brightness = v
        case "saturation": saturation = v
        case "highlight": highlight = v
        case "shadow": shadow = v
        case "white": white = v
        case "black": black = v
        case "clarity": clarity = v
        case "structure": structure = v
        case "dehaze": dehaze = v
        default: break
        }
    }

    /// Value used for rendering, clamped to the range.
    static func effective(_ s: DevelopSettings) -> DevelopSettings {
        var e = s
        for (name, key) in keys {
            let f = factor(name)
            guard f != 1, e[keyPath: key] != 0 else { continue }
            e[keyPath: key] *= f
        }
        e.saturation = max(e.saturation, -100)
        e.highlightTone = min(max(e.highlightTone, -100), 100)
        e.shadow = min(max(e.shadow, -100), 100)
        e.dehaze = min(max(e.dehaze, 0), 100)
        return e
    }
}
