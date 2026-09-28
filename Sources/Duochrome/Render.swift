import CoreImage
import Metal

/// 앱 전체가 함께 쓰는 GPU 자원. CIContext는 만들 때 비싸고 스레드에 안전하다.
enum Render {
    static let device = MTLCreateSystemDefaultDevice()!
    static let queue = device.makeCommandQueue()!
    static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!
    /// 작업 공간은 선형 Rec.2020 반정밀도 부동소수점. 카메라 색역을 거의 담는다.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let context = CIContext(mtlCommandQueue: queue, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
    ])
    /// 원본 크기 내보내기 전용: 중간 결과를 남기지 않는다 (45MP 중간 그림이 캐시에 쌓여 메모리를 몇 GB씩 잡았다)
    static let exportContext = CIContext(mtlCommandQueue: device.makeCommandQueue()!, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// 화면 기준으로 끝까지 간 곳을 칠한다. 하이라이트는 빨강, 섀도는 파랑.
    /// 교정쇄: sRGB로 바꿔 0~1로 자른 뒤 되돌린다. `warn`이면 잘린 화소(색역 밖)를 회색으로 칠한다.
    static func softProof(_ img: CIImage, warn: Bool) -> CIImage {
        // 고른 출력 프로파일이 있으면 그걸로 (PhotoWorkflow.swift)
        if ProofProfile.current != nil, let p = ProofProfile.apply(img, warn: warn) { return p }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let inS = img.matchedFromWorkingSpace(to: srgb) else { return img }
        let clamped = inS.applyingFilter("CIColorClamp")
        guard let back = clamped.matchedToWorkingSpace(from: srgb) else { return img }
        guard warn else { return back }
        return GPU.run("gamut_warn", [inS, clamped, back], extent: img.extent)
    }

    static func clippingOverlay(_ img: CIImage) -> CIImage {
        // 화면 색 공간 값으로 바꿔서 판단한다. 작업 공간 값은 1을 넘어도 화면에서 안 날아갈 수 있다.
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
