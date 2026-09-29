import AppKit

/// Layer-edit mode tools. Split by category, with added tools like straighten, keystone, and patch.
/// `ready` false means the tool isn't built yet (dimmed; the options panel shows the checklist item).
struct StudioTool: Equatable {
    enum Group: String, CaseIterable {
        case basic = "기본", selecting = "선택", painting = "칠하기", retouching = "리터칭", shaping = "형태", drawing = "도형과 텍스트"
    }

    let id: String
    let title: String
    let symbols: [String]
    let group: Group
    let ready: Bool
    /// Planned options shown dimmed in the tool options panel (tools not built yet).
    var plannedOptions: [String] = []
    var key: String = ""

    var image: NSImage {
        for s in symbols {
            if let i = NSImage(systemSymbolName: s, accessibilityDescription: title) { return i }
        }
        return NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: title)!
    }

    static func named(_ id: String) -> StudioTool? { all.first { $0.id == id } }

    /// Tool strip separator.
    static let separator = "|"

    static let all: [StudioTool] = [
        // basic
        .init(id: "arrange", title: "배치", symbols: ["cursorarrow"], group: .basic, ready: true, key: "v"),
        .init(id: "style", title: "스타일", symbols: ["wand.and.stars.inverse", "wand.and.stars"], group: .basic, ready: true,
              plannedOptions: ["그림자", "외부 광선", "획", "색상 오버레이"]),
        .init(id: "adjust", title: "색 조정", symbols: ["camera.filters", "slider.horizontal.3"], group: .basic, ready: true, key: "a"),
        .init(id: "effects", title: "효과", symbols: ["sparkles"], group: .basic, ready: true,
              plannedOptions: ["흐림", "선명", "왜곡", "스타일화"]),
        .init(id: "zoom", title: "확대/축소", symbols: ["magnifyingglass"], group: .basic, ready: true, key: "z"),
        .init(id: "hand", title: "손", symbols: ["hand.raised"], group: .basic, ready: true, key: "h"),
        .init(id: "picker", title: "색상 피커", symbols: ["eyedropper"], group: .basic, ready: true, key: "i"),
        .init(id: "crop", title: "자르기", symbols: ["crop"], group: .basic, ready: true, key: "c"),
        .init(id: "measure", title: "측정", symbols: ["ruler"], group: .basic, ready: true),
        .init(id: "count", title: "계수", symbols: ["number.circle"], group: .basic, ready: true),
        .init(id: "export", title: "내보내기", symbols: ["square.and.arrow.up"], group: .basic, ready: true),
        .init(id: "exportWeb", title: "웹용 내보내기", symbols: ["globe"], group: .basic, ready: true,
              plannedOptions: ["형식", "품질", "크기", "용량 미리보기"]),
        // selection
        .init(id: "selRect", title: "사각형 선택", symbols: ["rectangle.dashed"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기·교차", "비율 고정", "페더"], key: "m"),
        .init(id: "selOval", title: "타원 선택", symbols: ["circle.dashed"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기·교차", "비율 고정", "페더"]),
        .init(id: "selRow", title: "행 선택", symbols: ["arrow.left.and.right"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기"]),
        .init(id: "selColumn", title: "열 선택", symbols: ["arrow.up.and.down"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기"]),
        .init(id: "selFree", title: "자유 선택", symbols: ["lasso"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기·교차", "페더"], key: "l"),
        .init(id: "selPolygon", title: "다각형 선택", symbols: ["pentagon", "hexagon"], group: .selecting, ready: true,
              plannedOptions: ["더하기·빼기·교차", "페더"]),
        .init(id: "selMagnetic", title: "자석 선택", symbols: ["lasso.badge.sparkles", "lasso"], group: .selecting, ready: true,
              plannedOptions: ["폭", "대비", "모든 레이어 대상"]),
        .init(id: "selQuick", title: "빠른 선택", symbols: ["wand.and.rays"], group: .selecting, ready: true,
              plannedOptions: ["크기", "모든 레이어 대상", "가장자리 다듬기"], key: "w"),
        .init(id: "selWand", title: "자동 선택", symbols: ["wand.and.stars"], group: .selecting, ready: true,
              plannedOptions: ["허용치", "인접 영역만"]),
        .init(id: "selColor", title: "색상 선택", symbols: ["drop.halffull"], group: .selecting, ready: true,
              plannedOptions: ["허용치", "인접 영역만", "모든 레이어 대상"]),
        .init(id: "selSubject", title: "대상 선택", symbols: ["person.crop.rectangle"], group: .selecting, ready: true,
              plannedOptions: ["피사체", "하늘", "배경"]),
        .init(id: "selObject", title: "개체 선택", symbols: ["viewfinder", "person.crop.rectangle"], group: .selecting, ready: true),
        // painting
        .init(id: "maskPaint", title: "마스크 칠하기", symbols: ["circle.lefthalf.filled.righthalf.striped.horizontal", "circle.lefthalf.filled"],
              group: .painting, ready: true, key: "b"),
        .init(id: "paint", title: "칠하기", symbols: ["paintbrush.pointed"], group: .painting, ready: true,
              plannedOptions: ["브러시", "크기", "불투명도", "흐름", "경도", "혼합 모드"]),
        .init(id: "pixelPaint", title: "픽셀 칠하기", symbols: ["pencil"], group: .painting, ready: true,
              plannedOptions: ["크기", "불투명도"]),
        .init(id: "fill", title: "색 채우기", symbols: ["drop.fill"], group: .painting, ready: true,
              plannedOptions: ["색", "허용치", "인접 영역만"]),
        .init(id: "gradient", title: "그라디언트 채우기", symbols: ["square.bottomhalf.filled"], group: .painting, ready: true,
              plannedOptions: ["그라디언트", "종류", "불투명도"], key: "g"),
        .init(id: "erase", title: "지우기", symbols: ["eraser"], group: .painting, ready: true,
              plannedOptions: ["크기", "불투명도", "경도"], key: "e"),
        .init(id: "aiRemove", title: "AI 지우기", symbols: ["wand.and.rays.inverse", "eraser"], group: .painting, ready: true),
        .init(id: "smartErase", title: "스마트 지우기", symbols: ["eraser.line.dashed", "eraser"], group: .painting, ready: true),
        // retouching
        .init(id: "repair", title: "복구", symbols: ["bandage"], group: .retouching, ready: true, key: "j"),
        .init(id: "clone", title: "복제", symbols: ["stamp", "square.on.square.dashed"], group: .retouching, ready: true, key: "s"),
        .init(id: "patch", title: "패치", symbols: ["square.dashed.inset.filled", "lasso"], group: .retouching, ready: true),
        .init(id: "sharpen", title: "선명하게", symbols: ["triangle"], group: .retouching, ready: true,
              plannedOptions: ["크기", "세기", "가장자리 부드러움"]),
        .init(id: "soften", title: "부드럽게", symbols: ["drop"], group: .retouching, ready: true,
              plannedOptions: ["크기", "세기", "가장자리 부드러움"]),
        .init(id: "smudge", title: "문지르기", symbols: ["hand.point.up.left"], group: .retouching, ready: true,
              plannedOptions: ["크기", "세기", "가장자리 부드러움"]),
        .init(id: "lighten", title: "밝게", symbols: ["sun.max"], group: .retouching, ready: true,
              plannedOptions: ["크기", "노출", "범위 (섀도·중간·하이라이트)"], key: "o"),
        .init(id: "darken", title: "어둡게", symbols: ["moon"], group: .retouching, ready: true,
              plannedOptions: ["크기", "노출", "범위 (섀도·중간·하이라이트)"]),
        .init(id: "saturate", title: "채도 높이기", symbols: ["circle.fill"], group: .retouching, ready: true,
              plannedOptions: ["크기", "세기"]),
        .init(id: "desaturate", title: "채도 낮추기", symbols: ["circle.dotted"], group: .retouching, ready: true,
              plannedOptions: ["크기", "세기"]),
        .init(id: "distort", title: "왜곡", symbols: ["scribble.variable", "scribble"], group: .retouching, ready: true,
              plannedOptions: ["브러시 크기", "세기"]),
        .init(id: "bump", title: "범프", symbols: ["circle.circle"], group: .retouching, ready: true,
              plannedOptions: ["브러시 크기", "세기"]),
        .init(id: "pinch", title: "핀치", symbols: ["arrow.down.right.and.arrow.up.left"], group: .retouching, ready: true,
              plannedOptions: ["브러시 크기", "세기"]),
        .init(id: "twirl", title: "휘감기", symbols: ["tornado"], group: .retouching, ready: true,
              plannedOptions: ["브러시 크기", "세기", "방향"]),
        // geometry (batch-edit tools)
        .init(id: "straighten", title: "수평", symbols: ["level", "ruler"], group: .shaping, ready: true),
        .init(id: "keystone", title: "키스톤", symbols: ["perspective", "trapezoid.and.line.vertical"], group: .shaping, ready: true, key: "k"),
        .init(id: "whiteBalance", title: "화이트 밸런스", symbols: ["eyedropper.halffull"], group: .shaping, ready: true),
        .init(id: "transform", title: "변형", symbols: ["skew"], group: .shaping, ready: true,
              plannedOptions: ["크기", "회전", "기울이기", "원근", "뒤틀기"], key: "⌘T"),
        // shapes and text
        .init(id: "text", title: "텍스트", symbols: ["textformat"], group: .drawing, ready: true,
              plannedOptions: ["글꼴", "크기", "색", "정렬"], key: "t"),
        .init(id: "pen", title: "펜", symbols: ["pencil.and.outline"], group: .drawing, ready: true,
              plannedOptions: ["모드", "획", "채우기"], key: "p"),
        .init(id: "shape", title: "도형", symbols: ["square.on.circle"], group: .drawing, ready: true,
              plannedOptions: ["모양", "채우기", "획", "모서리"], key: "u"),
    ]

    /// Default tool strip.
    static let defaultStrip: [String] = [
        "arrange", "picker", "|", "adjust", "effects", "|", "selRect", "selFree", "selQuick", "|",
        "paint", "fill", "gradient", "erase", "aiRemove", "|", "repair", "clone", "patch", "lighten", "darken", "distort", "|",
        "text", "shape", "|", "hand", "zoom", "crop", "maskPaint",
    ]

    static var strip: [String] {
        get { UserDefaults.standard.stringArray(forKey: "studioStrip") ?? defaultStrip }
        set { UserDefaults.standard.set(newValue, forKey: "studioStrip") }
    }
}
