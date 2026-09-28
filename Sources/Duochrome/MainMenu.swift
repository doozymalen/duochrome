import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "Duochrome")
        app.addItem(withTitle: "Duochrome 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "설정…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Duochrome 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "기타 가리기", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Duochrome 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "파일")
        file.addItem(withTitle: "폴더 열기…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        let openFile = file.addItem(withTitle: "사진 열기…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        openFile.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Duochrome 문서로 저장…", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        let exp = file.addItem(withTitle: "내보내기…", action: #selector(MainWindowController.exportPhotos(_:)), keyEquivalent: "e")
        exp.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "웹용 내보내기…", action: #selector(MainWindowController.exportForWeb(_:)), keyEquivalent: "")
        let pr = file.addItem(withTitle: "인쇄…", action: #selector(MainWindowController.printPhoto(_:)), keyEquivalent: "p")
        pr.keyEquivalentModifierMask = [.command]
        file.addItem(withTitle: "PSD로 내보내기 (PSD·PSB)…", action: #selector(MainWindowController.exportPSD(_:)), keyEquivalent: "")
        file.addItem(withTitle: "색 조정을 LUT로 내보내기 (.cube)…", action: #selector(MainWindowController.exportLUT(_:)), keyEquivalent: "")
        file.addItem(withTitle: "DNG로 저장…", action: #selector(MainWindowController.exportDNG(_:)), keyEquivalent: "")
        file.addItem(.separator())
        let catalogItem = file.addItem(withTitle: "카탈로그 가져오기 (.cocatalog)…", action: #selector(MainWindowController.importExternalCatalog(_:)), keyEquivalent: "i")
        catalogItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "세션 보정값 가져오기 (.cos)…", action: #selector(MainWindowController.importSidecarImport(_:)), keyEquivalent: "")
        file.addItem(withTitle: "스타일 가져오기 (.costyle)…", action: #selector(MainWindowController.importStyleFiles(_:)), keyEquivalent: "")
        file.addItem(withTitle: "프리셋 가져오기 (브러시·그라디언트·패턴·견본)…", action: #selector(MainWindowController.importPresets(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(in: main, title: "편집")
        edit.addItem(withTitle: "실행 취소", action: #selector(MainWindowController.undoAdjust(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "다시 실행", action: #selector(MainWindowController.redoAdjust(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        // 표준 편집 명령 (숫자 입력칸·검색칸에서 쓰인다). 입력칸 밖의 ⌘V는 클립보드 그림을 레이어로 붙인다.
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let copyAdj = edit.addItem(withTitle: "조정 복사", action: #selector(MainWindowController.copyAdjustments(_:)), keyEquivalent: "c")
        copyAdj.keyEquivalentModifierMask = [.command, .shift]
        let pasteAdj = edit.addItem(withTitle: "조정 적용", action: #selector(MainWindowController.pasteAdjustments(_:)), keyEquivalent: "v")
        pasteAdj.keyEquivalentModifierMask = [.command, .shift]
        let pasteSome = edit.addItem(withTitle: "조정 골라 적용…", action: #selector(MainWindowController.pasteAdjustmentsChoosing(_:)), keyEquivalent: "v")
        pasteSome.keyEquivalentModifierMask = [.command, .shift, .option]
        edit.addItem(withTitle: "조정 초기화", action: #selector(MainWindowController.resetAdjustments(_:)), keyEquivalent: "")

        let layerMenu = submenu(in: main, title: "레이어")
        layerMenu.addItem(withTitle: "피사체 선택 (AI)", action: #selector(MainWindowController.selectSubjectAI(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "배경 선택 (AI)", action: #selector(MainWindowController.selectBackgroundAI(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "사람 선택 (AI)", action: #selector(MainWindowController.selectPersonAI(_:)), keyEquivalent: "")
        layerMenu.addItem(.separator())
        layerMenu.addItem(withTitle: "이미지 레이어 가져오기…", action: #selector(MainWindowController.placeImageLayer(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "클립보드 그림 붙여넣기 (⌘V)", action: #selector(MainWindowController.pasteImageLayer(_:)), keyEquivalent: "")
        layerMenu.addItem(.separator())
        layerMenu.addItem(withTitle: "복제 (레이어 / 배경)", action: #selector(MainWindowController.duplicateLayerOrBackground(_:)), keyEquivalent: "j")
        layerMenu.addItem(withTitle: "자유 변형", action: #selector(MainWindowController.freeTransform(_:)), keyEquivalent: "t")
        layerMenu.addItem(withTitle: "그룹으로 묶기", action: #selector(MainWindowController.groupLayer(_:)), keyEquivalent: "g")
        let ungroup = layerMenu.addItem(withTitle: "그룹 풀기", action: #selector(MainWindowController.ungroupLayer(_:)), keyEquivalent: "g")
        ungroup.keyEquivalentModifierMask = [.command, .shift]
        layerMenu.addItem(.separator())
        // 병합 — 단축키는 KeyMap
        layerMenu.addItem(withTitle: "아래 레이어와 병합", action: #selector(MainWindowController.mergeDown(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "보이는 레이어 병합", action: #selector(MainWindowController.mergeVisible(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "보이는 레이어 도장 찍기", action: #selector(MainWindowController.stampVisible(_:)), keyEquivalent: "")
        layerMenu.addItem(.separator())
        layerMenu.addItem(withTitle: "아래 레이어와 연결 / 연결 풀기", action: #selector(MainWindowController.toggleLinkBelow(_:)), keyEquivalent: "")
        let align = layerMenu.addItem(withTitle: "정렬", action: nil, keyEquivalent: "")
        let alignMenu = NSMenu()
        for (t, e) in [("왼쪽 가장자리", 0), ("가로 가운데", 1), ("오른쪽 가장자리", 2), ("위쪽 가장자리", 3), ("세로 가운데", 4), ("아래쪽 가장자리", 5)] {
            let i = alignMenu.addItem(withTitle: t, action: #selector(MainWindowController.alignFromMenu(_:)), keyEquivalent: "")
            i.tag = e
        }
        alignMenu.addItem(.separator())
        alignMenu.addItem(withTitle: "연결된 레이어 가로로 분배", action: #selector(MainWindowController.distributeH(_:)), keyEquivalent: "")
        alignMenu.addItem(withTitle: "연결된 레이어 세로로 분배", action: #selector(MainWindowController.distributeV(_:)), keyEquivalent: "")
        align.submenu = alignMenu
        let comps = layerMenu.addItem(withTitle: "레이어 구성", action: nil, keyEquivalent: "")
        comps.submenu = NSMenu()
        comps.submenu?.delegate = LayerCompMenuDelegate.shared
        layerMenu.addItem(.separator())
        layerMenu.addItem(withTitle: "연결된 이미지 레이어 가져오기…", action: #selector(MainWindowController.placeLinkedImage(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "연결된 이미지를 내장으로", action: #selector(MainWindowController.embedLinkedImage(_:)), keyEquivalent: "")

        // 선택 — 단축키는 KeyMap
        let selMenu = submenu(in: main, title: "선택")
        for (t, sel) in [("선택 해제", #selector(MainWindowController.deselectAll(_:))), ("선택 반전", #selector(MainWindowController.invertSelection(_:))),
                         ("확장…", #selector(MainWindowController.expandSelection(_:))), ("축소…", #selector(MainWindowController.contractSelection(_:))),
                         ("페더…", #selector(MainWindowController.featherSelection(_:))), ("테두리…", #selector(MainWindowController.borderSelection(_:))),
                         ("매끄럽게…", #selector(MainWindowController.smoothSelection(_:))), ("초점 영역", #selector(MainWindowController.selectFocusArea(_:))),
                         ("선택 및 마스크…", #selector(MainWindowController.showSelectAndMask(_:))), ("퀵 마스크", #selector(MainWindowController.toggleQuickMask(_:)))] {
            selMenu.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        selMenu.addItem(.separator())
        let chItem = selMenu.addItem(withTitle: "알파 채널", action: nil, keyEquivalent: "")
        chItem.submenu = NSMenu()
        chItem.submenu?.delegate = ChannelsMenuDelegate.shared

        // AI — 모두 이 맥 안에서만, Duochrome 안의 보이지 않는 엔진으로
        let ai = submenu(in: main, title: "AI")
        for (t, sel) in [("하늘 선택", #selector(MainWindowController.selectSkyAI(_:))), ("스킨 선택", #selector(MainWindowController.skinMaskAI(_:))),
                         ("피부 매끄럽게", #selector(MainWindowController.skinSmoothAI(_:))), ("배경 지우기 (켜기/끄기)", #selector(MainWindowController.removeBackgroundAI(_:))),
                         ("자르기 추천", #selector(MainWindowController.suggestCropAI(_:)))] {
            ai.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        ai.addItem(.separator())
        for (t, sel) in [("생성형 채우기…", #selector(MainWindowController.generativeFillFromMenu(_:))),
                         ("생성형 확장 (새 사진)…", #selector(MainWindowController.generativeExpandFromMenu(_:))),
                         ("AI 노이즈 제거", #selector(MainWindowController.aiDenoise(_:))),
                         ("반사 제거 (유리창)", #selector(MainWindowController.aiRemoveReflection(_:))),
                         ("2배 확대 (새 파일)", #selector(MainWindowController.aiUpscale2x(_:)))] {
            ai.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        ai.addItem(.separator())
        ai.addItem(withTitle: "AI 엔진 켜기·끄기", action: #selector(MainWindowController.toggleAIEngine(_:)), keyEquivalent: "")
        ai.addItem(withTitle: "코랩 끄기 (사용량 아끼기)", action: #selector(MainWindowController.stopColab(_:)), keyEquivalent: "")
        ai.addItem(withTitle: "AI 엔진 설치·다시 설치", action: #selector(MainWindowController.reinstallAIEngine(_:)), keyEquivalent: "")

        let view = submenu(in: main, title: "보기")
        view.addItem(withTitle: "화면에 맞추기", action: #selector(MainWindowController.zoomToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "실제 픽셀", action: #selector(MainWindowController.zoomToActual(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "확대", action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "축소", action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "HDR로 보기 (EDR 화면)", action: #selector(MainWindowController.toggleHDRView(_:)), keyEquivalent: "")
        view.addItem(withTitle: "초점 확인 (100% 확대 창)", action: #selector(MainWindowController.toggleFocusLoupe(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "눈금자", action: #selector(MainWindowController.toggleRulers(_:)), keyEquivalent: "")
        view.addItem(withTitle: "안내선 보기", action: #selector(MainWindowController.toggleGuides(_:)), keyEquivalent: "")
        view.addItem(withTitle: "스냅", action: #selector(MainWindowController.toggleSnap(_:)), keyEquivalent: "")
        view.addItem(withTitle: "가운데 안내선 만들기", action: #selector(MainWindowController.newGuideAtCenter(_:)), keyEquivalent: "")
        view.addItem(withTitle: "안내선 지우기", action: #selector(MainWindowController.clearGuides(_:)), keyEquivalent: "")
        view.addItem(.separator())
        let second = view.addItem(withTitle: "두 번째 화면에 보기", action: #selector(MainWindowController.toggleSecondViewer(_:)), keyEquivalent: "v")
        second.keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "교정쇄 보기 (sRGB)", action: #selector(MainWindowController.toggleSoftProof(_:)), keyEquivalent: "y")
        let gamut = view.addItem(withTitle: "색역 경고 (sRGB)", action: #selector(MainWindowController.toggleGamutWarning(_:)), keyEquivalent: "y")
        gamut.keyEquivalentModifierMask = [.command, .shift]
        let before = view.addItem(withTitle: "보정 전 보기", action: #selector(MainWindowController.toggleOriginal(_:)), keyEquivalent: "y")
        before.keyEquivalentModifierMask = []
        let split = view.addItem(withTitle: "전후 나란히", action: #selector(MainWindowController.toggleSplitCompare(_:)), keyEquivalent: "Y")
        split.keyEquivalentModifierMask = [.shift]
        let grid = view.addItem(withTitle: "구도 격자 바꾸기 (없음 → 3분할 → 격자 → 황금 분할)", action: #selector(MainWindowController.cycleGrid(_:)), keyEquivalent: "'")
        grid.keyEquivalentModifierMask = [.command]
        let clip = view.addItem(withTitle: "클리핑 경고", action: #selector(MainWindowController.toggleClipping(_:)), keyEquivalent: "j")
        clip.keyEquivalentModifierMask = []

        view.addItem(.separator())
        // 커서 도구 단축키는 KeyMap이 모드별로 받는다 (대량 보정·심화 보정). 메뉴에는 이름만.
        for (title, sel) in [("이동 도구", #selector(MainWindowController.toolPan(_:))),
                             ("확대 도구", #selector(MainWindowController.toolZoom(_:))),
                             ("크롭 도구", #selector(MainWindowController.toolCrop(_:))),
                             ("수평 도구", #selector(MainWindowController.toolStraighten(_:))),
                             ("키스톤 선 도구", #selector(MainWindowController.toolKeystone(_:))),
                             ("화이트 밸런스 스포이트", #selector(MainWindowController.toolWhiteBalance(_:))),
                             ("리터칭 도구", #selector(MainWindowController.toolRetouch(_:))),
                             ("마스크 도구", #selector(MainWindowController.toolMask(_:))),
                             ("마스크 보기", #selector(MainWindowController.toggleMaskView(_:))),
                             ("붓 작게", #selector(MainWindowController.brushSmaller(_:))),
                             ("붓 크게", #selector(MainWindowController.brushLarger(_:)))] {
            view.addItem(withTitle: title, action: sel, keyEquivalent: "")
        }

        let modes = submenu(in: main, title: "모드")
        for (m, sel) in [(AppMode.edit, #selector(MainWindowController.switchToEdit(_:))),
                         (.library, #selector(MainWindowController.switchToLibrary(_:))),
                         (.studio, #selector(MainWindowController.switchToStudio(_:))),
                         (.tether, #selector(MainWindowController.switchToTether(_:)))] {
            // 모드 전환: ⌥⌘1~4 (한 글자는 두 모드에서 도구 단축키로 쓴다)
            let item = modes.addItem(withTitle: m == .library ? "대량 보정 — 격자 보기" : "\(m.title) 모드", action: sel,
                                     keyEquivalent: "\([.edit: 1, .library: 2, .studio: 3, .tether: 4][m] ?? 1)")
            item.keyEquivalentModifierMask = [.command, .option]
        }

        let photo = submenu(in: main, title: "사진")
        let auto = photo.addItem(withTitle: "자동 조정", action: #selector(MainWindowController.autoAdjust(_:)), keyEquivalent: "a")
        auto.keyEquivalentModifierMask = [.command, .shift]
        let styleItem = photo.addItem(withTitle: "스타일", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu(title: "스타일")
        styleMenu.delegate = StyleMenuDelegate.shared
        let modeItem = photo.addItem(withTitle: "모드", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "모드")
        modeMenu.delegate = ColorModeMenuDelegate.shared
        modeItem.submenu = modeMenu
        let actItem = photo.addItem(withTitle: "동작", action: nil, keyEquivalent: "")
        let actMenu = NSMenu(title: "동작")
        actMenu.delegate = ActionMenuDelegate.shared
        actItem.submenu = actMenu
        styleItem.submenu = styleMenu
        photo.addItem(.separator())
        for n in 0...5 {
            let item = photo.addItem(withTitle: n == 0 ? "별점 지우기" : "별점 " + String(repeating: "★", count: n),
                                     action: #selector(MainWindowController.rateFromMenu(_:)), keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = []
            item.tag = n
        }
        photo.addItem(.separator())
        for (i, (name, _)) in colorTags.enumerated() {
            let item = photo.addItem(withTitle: "색 태그: \(name)", action: #selector(MainWindowController.colorFromMenu(_:)),
                                     keyEquivalent: i == 0 ? "" : "\(i)")
            item.keyEquivalentModifierMask = [.option]
            item.tag = i
        }

        photo.addItem(.separator())
        for (t, tag) in [("채택 (P)", 1), ("거부 (X)", -1), ("채택·거부 지우기 (U)", 0)] {
            photo.addItem(withTitle: t, action: #selector(MainWindowController.flagFromMenu(_:)), keyEquivalent: "").tag = tag
        }
        photo.addItem(.separator())
        for (t, sel) in [("불러오기…", #selector(MainWindowController.importPhotos(_:))),
                         ("변형본 만들기", #selector(MainWindowController.makeVariant(_:))),
                         ("일괄 이름 바꾸기…", #selector(MainWindowController.batchRename(_:))),
                         ("촬영 시각 고치기…", #selector(MainWindowController.adjustCaptureTime(_:))),
                         ("XMP 사이드카 쓰기", #selector(MainWindowController.writeXMPSidecars(_:))),
                         ("XMP 사이드카 읽기", #selector(MainWindowController.readXMPSidecars(_:))),
                         ("오프라인 원본 다시 잇기…", #selector(MainWindowController.relinkOffline(_:))),
                         ("고른 사진 비교 보기", #selector(MainWindowController.toggleCompare(_:))),
                         ("여러 장 같이 보정 (켜기·끄기)", #selector(MainWindowController.toggleMultiEdit(_:)))] {
            photo.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        photo.addItem(.separator())
        for (t, sel) in [("스타일 브러시…", #selector(MainWindowController.styleBrush(_:))),
                         ("룩 맞추기 기준으로 삼기", #selector(MainWindowController.setLookReference(_:))),
                         ("룩 맞추기 (기준 사진 색감으로)", #selector(MainWindowController.matchLook(_:))),
                         ("노멀라이즈 기준색 집기", #selector(MainWindowController.pickNormalizeReference(_:))),
                         ("노멀라이즈 (누른 곳을 기준색으로)", #selector(MainWindowController.pickNormalizeTarget(_:)))] {
            photo.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        let mergeItem = photo.addItem(withTitle: "합치기", action: nil, keyEquivalent: "")
        let mergeMenu = NSMenu(title: "합치기")
        for (t, sel) in [("HDR 합치기", #selector(MainWindowController.mergeHDR(_:))),
                         ("파노라마…", #selector(MainWindowController.mergePanorama(_:))),
                         ("초점 스태킹", #selector(MainWindowController.mergeFocus(_:))),
                         ("이미지 스택: 중앙값 (움직이는 것 지우기)", #selector(MainWindowController.mergeMedian(_:))),
                         ("이미지 스택: 평균 (노이즈 줄이기)", #selector(MainWindowController.mergeMean(_:)))] {
            mergeMenu.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        mergeMenu.addItem(.separator())
        mergeMenu.addItem(withTitle: "LCC 만들기 (지금 사진이 LCC)", action: #selector(MainWindowController.makeLCC(_:)), keyEquivalent: "")
        mergeMenu.addItem(withTitle: "LCC 적용…", action: #selector(MainWindowController.applyLCC(_:)), keyEquivalent: "")
        mergeItem.submenu = mergeMenu
        layerMenu.addItem(.separator())
        let tf = layerMenu.addItem(withTitle: "변형", action: nil, keyEquivalent: "")
        let tfm = NSMenu(title: "변형")
        for (t, sel) in [("자유 변형 (크기·회전) ⌘T", #selector(MainWindowController.freeTransform(_:))),
                         ("기울이기", #selector(MainWindowController.skewLayer(_:))), ("왜곡", #selector(MainWindowController.distortLayer(_:))),
                         ("원근", #selector(MainWindowController.perspectiveLayer(_:))), ("뒤틀기 (격자)", #selector(MainWindowController.warpLayer(_:))),
                         ("퍼펫 뒤틀기", #selector(MainWindowController.puppetWarp(_:))), ("내용 인식 비율…", #selector(MainWindowController.contentAwareScale(_:)))] {
            tfm.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        tf.submenu = tfm
        let lq = layerMenu.addItem(withTitle: "픽셀 유동화", action: nil, keyEquivalent: "")
        let lqm = NSMenu(title: "픽셀 유동화")
        for (t, sel) in [("밀기", #selector(MainWindowController.liquifyPush(_:))), ("부풀리기", #selector(MainWindowController.liquifyBloat(_:))),
                         ("오목", #selector(MainWindowController.liquifyPucker(_:))), ("돌리기 (⌥ 반대)", #selector(MainWindowController.liquifyTwirl(_:))),
                         ("되돌리기 붓", #selector(MainWindowController.liquifyReconstruct(_:))), ("얼굴 인식 유동화…", #selector(MainWindowController.faceAwareLiquify(_:)))] {
            lqm.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        lq.submenu = lqm
        let pm = layerMenu.addItem(withTitle: "칠하기", action: nil, keyEquivalent: "")
        let pmm = NSMenu(title: "칠하기")
        for (t, sel) in [("브러시 (칠 레이어)", #selector(MainWindowController.paintBrushMenu(_:))), ("연필", #selector(MainWindowController.pencilMenu(_:))),
                         ("혼합 브러시", #selector(MainWindowController.mixerBrushMenu(_:))), ("픽셀 칠하기", #selector(MainWindowController.pixelPaintMenu(_:))),
                         ("지우개", #selector(MainWindowController.eraserMenu(_:))), ("배경 지우개", #selector(MainWindowController.backgroundEraserTool(_:))),
                         ("페인트 통", #selector(MainWindowController.paintBucketTool(_:))), ("작업 내역 브러시…", #selector(MainWindowController.historyBrush(_:))),
                         ("적목 현상 제거", #selector(MainWindowController.redEyeTool(_:)))] {
            pmm.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        pm.submenu = pmm
        let ld = layerMenu.addItem(withTitle: "렌즈 흐림 깊이 맵", action: nil, keyEquivalent: "")
        let ldm = NSMenu(title: "렌즈 흐림 깊이 맵")
        ldm.addItem(withTitle: "AI 피사체 분리로", action: #selector(MainWindowController.lensDepthFromAI(_:)), keyEquivalent: "")
        ldm.addItem(withTitle: "사진의 깊이 자료로 (인물 사진 HEIC)", action: #selector(MainWindowController.lensDepthFromPhoto(_:)), keyEquivalent: "")
        ldm.addItem(withTitle: "고른 레이어의 마스크로", action: #selector(MainWindowController.lensDepthFromMask(_:)), keyEquivalent: "")
        ld.submenu = ldm
        layerMenu.addItem(withTitle: "소실점…", action: #selector(MainWindowController.vanishingPoint(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "자동 정렬 레이어", action: #selector(MainWindowController.autoAlignLayers(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "자동 혼합 레이어…", action: #selector(MainWindowController.autoBlendLayers(_:)), keyEquivalent: "")
        let geo = photo.addItem(withTitle: "형태", action: nil, keyEquivalent: "")
        let geom = NSMenu(title: "형태")
        for (t, sel) in [("원근 자르기…", #selector(MainWindowController.perspectiveCrop(_:))), ("원근 자르기 풀기", #selector(MainWindowController.clearPerspectiveCrop(_:))),
                         ("캔버스 크기…", #selector(MainWindowController.canvasSize(_:))), ("캔버스 다듬기 (가장자리 잘라내기)", #selector(MainWindowController.trimCanvas(_:))),
                         ("이미지 크기…", #selector(MainWindowController.imageSize(_:))), ("적응형 광각…", #selector(MainWindowController.adaptiveWideAngle(_:)))] {
            geom.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        geo.submenu = geom
        view.addItem(withTitle: "교정쇄 프로파일 고르기…", action: #selector(MainWindowController.chooseProofProfile(_:)), keyEquivalent: "")

        let gray = view.addItem(withTitle: "마스크 흑백으로 보기", action: #selector(MainWindowController.toggleMaskGray(_:)), keyEquivalent: "m")
        gray.keyEquivalentModifierMask = [.option]

        let window = submenu(in: main, title: "윈도우")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "확대/축소", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let full = window.addItem(withTitle: "전체 화면", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        window.addItem(.separator())
        let jobsItem = window.addItem(withTitle: "작업 진행 창", action: #selector(MainWindowController.toggleJobsPanel(_:)), keyEquivalent: "j")
        jobsItem.keyEquivalentModifierMask = [.command, .option]
        window.addItem(.separator())
        let wsItem = window.addItem(withTitle: "작업 공간", action: nil, keyEquivalent: "")
        let wsMenu = NSMenu(title: "작업 공간")
        wsMenu.delegate = WorkspaceMenuDelegate.shared
        wsItem.submenu = wsMenu
        window.addItem(.separator())
        window.addItem(withTitle: "앞으로 가져오기", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(in: main, title: "도움말")
        help.addItem(withTitle: "단축키 보기", action: #selector(MainWindowController.showShortcuts(_:)), keyEquivalent: "/")
        help.addItem(withTitle: "지원 카메라…", action: #selector(MainWindowController.showSupportedCameras(_:)), keyEquivalent: "")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
