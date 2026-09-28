import Foundation

/// 슬라이더 반응 배율. 그릴 때 슬라이더 값에 곱한다 (저장된 값과 화면 숫자는 그대로).
///
/// 지금은 모두 1 (배율 없음).
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
        ("highlight", \.highlight), ("shadow", \.shadow), ("white", \.white), ("black", \.black),
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

    /// 그릴 때 쓰는 값. 범위를 넘지 않게 자른다.
    static func effective(_ s: DevelopSettings) -> DevelopSettings {
        var e = s
        for (name, key) in keys {
            let f = factor(name)
            guard f != 1, e[keyPath: key] != 0 else { continue }
            e[keyPath: key] *= f
        }
        e.saturation = max(e.saturation, -100)
        e.highlight = min(max(e.highlight, 0), 130)
        e.shadow = min(max(e.shadow, 0), 200)
        e.dehaze = min(max(e.dehaze, 0), 100)
        return e
    }
}
