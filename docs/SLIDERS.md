# Slider Definitions · 슬라이더 정의

<p><a href="#english">English</a> · <a href="#한국어">한국어</a></p>

## English

This document defines **how much** Duochrome's basic sliders change a photo. The values aren't fitted to another program's output; they're defined directly in terms of light (stops) and middle gray. The same value changes any photo by the same amount.

### Reference

- **Stop (EV)**: doubling the light is +1 stop, halving it is −1 stop.
- **Middle gray**: 18% reflectance gray (linear 0.18, about 0.46 on screen). The brightness a light meter targets.
- **Display brightness L**: linear luminance encoded with gamma 2.2 (0 black – 1 white). Used to split the highlight and shadow ranges.
- Tone curves (brightness, contrast, whites, blacks) are applied to display values (Display P3, sRGB transfer function). Highlights and shadows change luminance only and keep color ratios (hue, saturation).

### Exposure (−4 to +4)

| Value | Meaning |
|---|---|
| +1 | Every brightness exactly 1 stop brighter (linear ×2) |
| −1 | Every brightness 1 stop darker (linear ×½) |

For RAW files it's applied during decoding, so highlights that look blown can be recovered.

### Brightness (−100 to +100)

- **Moves middle gray by (value ÷ 100) stops**, leaving black (0) and white (1) in place.
- +100 takes middle gray 0.18 → 0.36 (+1 stop); −100 takes 0.18 → 0.09 (−1 stop).
- A gamma curve that moves the middle most and the ends less.

### Contrast (−100 to +100)

- An S-curve **pivoting on middle gray (after the brightness shift)**. The slope at the pivot becomes 2^(value ÷ 100).
- +100 doubles contrast around middle gray; −100 halves it.
- Middle gray, black, and white don't move. Overall brightness stays; only the difference between bright and dark areas changes.
- Film contrast from the base characteristics card adds to the same curve.

### Highlights (−100 to +100)

Moves only bright areas (display brightness L above 0.5). Middle gray and below stay put.

**+ (brighten)**: keeps 0.5 and white fixed and lifts what's between. At +100, L 0.83 rises most, to 0.91 (about +0.4 stop). Nothing passes white, so no new clipping appears.

**− (recover)**: pushes bright areas down in stops. At −100:

| Display brightness L | Amount pushed down |
|---|---|
| Below 0.5 (including middle gray) | 0 (unchanged) |
| 0.5 → 0.85 | Rises smoothly from 0 to 1 stop |
| 0.85 | 1 stop |
| 1.0 (white) | 0.5 stop (less, so white doesn't die into gray) |
| Above 1.0 (blown detail still in the RAW) | Folded smoothly into the headroom below white and recovered |

Smaller values scale proportionally (−50 is at most 0.5 stop).

**Local application**: in the develop panel, the highlights curve isn't applied pixel by pixel but to **an edge-preserving broad luminance (80 px radius at source scale)**, and the resulting ratio multiplies each pixel. Whole bright regions like sky or white walls follow the curve, while the contrast of texture within them (cloud detail, wall patterns) isn't reduced. Adjustment layers and LUT export apply it per pixel.

Highlight values saved by older versions (0–100, higher pushes more) are read as the same magnitude with a minus sign.

### Shadows (−100 to +100)

Moves only dark areas (display brightness L below 0.5). Middle gray stays nearly unchanged.

**+ (brighten)**: lifts dark areas in stops. At +100:

| Display brightness L | Amount lifted |
|---|---|
| Above 0.5 | 0 (unchanged) |
| Middle gray (L ≈ 0.46) | About 0.05 stop (nearly unchanged) |
| 0.5 → 0.2 | Rises smoothly from 0 to 1 stop |
| Below 0.2 | 1 stop |

It multiplies, so pure black stays black.

**− (deepen)**: keeps 0.5 and black fixed and lowers what's between. At −100, L 0.17 drops most, to 0.09 (about −1.9 stops), and middle gray moves only about 0.02 stop.

Smaller values scale proportionally.

**Local application**: like highlights, the develop panel's shadows apply the curve to an edge-preserving broad luminance (80 px radius) and multiply by the ratio. Whole dark regions like shaded walls or dark forests follow the curve, while texture contrast within them neither shrinks nor grows excessively. Adjustment layers and LUT export apply it per pixel.

### Whites · Blacks (−100 to +100)

Moves the white and black points by moving the ends of the curve. The effect falls off quickly toward the middle (cubic).

| Value | Meaning |
|---|---|
| Whites +100 | Display values above about 0.85 become white (pulls the white point down) |
| Whites −100 | White (1.0) drops to display value 0.75 |
| Blacks +100 | Black (0) rises to display value 0.10 (faded black) |
| Blacks −100 | Display values below about 0.075 become black (pulls the black point up) |

Even at ±100, middle gray moves no more than 0.03 in display value.

### Saturation (−100 to +100)

| Value | Meaning |
|---|---|
| −100 | Black and white (luminance unchanged) |
| +100 | Color strength (distance from gray) doubled |

### Clarity · Structure (−100 to +100)

An edge-preserving filter (guided filter) splits the photo's brightness into "broad flow" and "detail", then multiplies detail by (1 + 2 × value ÷ 100). +100 triples detail; −100 inverts it, erasing detail. Very dark areas (display below 0.15) and very bright areas (above 0.85) are affected less.

- **Clarity**: large-scale contrast with a 120 px radius (source scale)
- **Structure**: fine texture with a 12 px radius

Overall brightness and color stay nearly the same; only local contrast changes. Each method differs in strength and saturation: natural (strength ×1, slight saturation), punch (×1.4, more saturation), neutral (×1, saturation unchanged), classic (×1.2, weaker edge preservation).

### Dehaze (0 to 100)

Estimates and removes haze per area with the dark channel prior (He 2009). At 100 it removes 80% of the estimated haze (removing all of it tends to flip the sky dark). If a haze color is set, removal is relative to that color.

### Verification

The "slider definitions" item of the self test (`DUOCHROME_SELFTEST=1`) checks the numbers above: brightness +100 takes gray 0.18 → 0.36; contrast keeps gray fixed; highlights −100 halves L 0.85, +100 takes L 0.83 to 0.91, and bright-region texture is preserved; shadows +100 doubles L 0.1, −100 takes L 0.17 to 0.09, and dark-region texture is preserved.

---

## 한국어

Duochrome의 기본 슬라이더가 사진을 **얼마나** 바꾸는지 정한 문서입니다. 다른 프로그램의 결과에 맞춘 값이 아니라, 빛의 양(스톱)과 중간 회색을 기준으로 직접 정한 값입니다. 같은 값을 넣으면 어느 사진에서나 같은 만큼 바뀝니다.

### 기준

- **스톱(EV)**: 빛의 양이 두 배가 되면 +1스톱, 절반이 되면 −1스톱입니다.
- **중간 회색**: 반사율 18%인 회색(선형 값 0.18, 화면 값 약 0.46)입니다. 노출계가 맞추는 밝기입니다.
- **화면 밝기 L**: 선형 휘도를 감마 2.2로 부호화한 값(0 검정 ~ 1 흰색)입니다. 하이라이트·섀도의 구간을 나눌 때 씁니다.
- 톤 곡선(밝기·대비·화이트·블랙)은 화면 값(Display P3, sRGB 전달 함수)에서 겁니다. 하이라이트·섀도는 휘도만 바꾸고 색 비율(색조·채도)은 지킵니다.

### 노출 (−4 ~ +4)

| 값 | 뜻 |
|---|---|
| +1 | 모든 밝기를 정확히 1스톱 밝게 (선형 값 ×2) |
| −1 | 모든 밝기를 1스톱 어둡게 (선형 값 ×½) |

RAW 파일은 해독할 때 적용해서, 날아간 것처럼 보이던 밝은 부분도 되살릴 수 있습니다.

### 밝기 (−100 ~ +100)

- **중간 회색을 (값 ÷ 100)스톱 옮기고**, 검정(0)과 흰색(1)은 그대로 둡니다.
- +100이면 중간 회색 0.18 → 0.36 (+1스톱), −100이면 0.18 → 0.09 (−1스톱)입니다.
- 가운데를 가장 많이 움직이고 양끝으로 갈수록 덜 움직이는 감마 곡선입니다.

### 대비 (−100 ~ +100)

- **중간 회색(밝기로 옮긴 뒤의 위치)을 축으로** 한 S자 곡선입니다. 축의 기울기가 2^(값 ÷ 100)배가 됩니다.
- +100이면 중간 회색 부근의 대비가 2배, −100이면 ½배입니다.
- 중간 회색·검정·흰색은 움직이지 않습니다. 사진 전체 밝기는 그대로 두고 밝은 곳과 어두운 곳의 차이만 바뀝니다.
- 기본 특성 카드의 필름 대비도 같은 곡선에 더해집니다.

### 하이라이트 (−100 ~ +100)

밝은 부분(화면 밝기 L 0.5 위)만 움직입니다. 중간 회색과 그 아래는 그대로입니다.

**+ (밝게)**: 0.5와 흰색은 그대로 두고 그 사이를 올립니다. +100일 때 L 0.83이 0.91로(약 +0.4스톱) 가장 많이 오릅니다. 흰색을 넘기지 않으므로 새로 날아가는 곳은 생기지 않습니다.

**− (되살림)**: 밝은 부분을 스톱 단위로 누릅니다. −100일 때:

| 화면 밝기 L | 누르는 양 |
|---|---|
| 0.5 아래 (중간 회색 포함) | 0 (그대로) |
| 0.5 → 0.85 | 0에서 1스톱까지 부드럽게 늘어남 |
| 0.85 | 1스톱 |
| 1.0 (흰색) | 0.5스톱 (흰색이 회색으로 죽지 않게 덜) |
| 1.0 넘음 (RAW에 남은 날아간 부분) | 흰색 아래 남은 여유 안으로 부드럽게 접어 되살림 |

값이 작으면 비례해서 줄어듭니다(−50이면 최대 0.5스톱).

**국소 적용**: 현상 패널의 하이라이트는 곡선을 픽셀 하나하나가 아니라 **가장자리를 지키는 넓은 밝기(반경 80픽셀, 원본 기준)** 에 걸고, 그 배율을 픽셀에 곱합니다. 하늘·흰 벽처럼 밝은 구역 전체는 곡선대로 옮겨지지만, 그 안의 질감(구름 결, 벽 무늬)의 명암 차이는 줄지 않습니다. 조정 레이어와 LUT 내보내기에서는 한 픽셀씩 겁니다.

예전 버전에서 저장한 하이라이트 값(0~100, 클수록 누름)은 같은 크기의 −값으로 읽습니다.

### 섀도 (−100 ~ +100)

어두운 부분(화면 밝기 L 0.5 아래)만 움직입니다. 중간 회색은 거의 그대로입니다.

**+ (밝게)**: 어두운 부분을 스톱 단위로 밝힙니다. +100일 때:

| 화면 밝기 L | 밝히는 양 |
|---|---|
| 0.5 위 | 0 (그대로) |
| 중간 회색(L 약 0.46) | 0.05스톱 정도 (거의 그대로) |
| 0.5 → 0.2 | 0에서 1스톱까지 부드럽게 늘어남 |
| 0.2 아래 | 1스톱 |

곱하는 방식이라 순수한 검정은 검정으로 남습니다.

**− (깊게)**: 0.5와 검정은 그대로 두고 그 사이를 내립니다. −100일 때 L 0.17이 0.09로(약 −1.9스톱) 가장 많이 내려가고, 중간 회색은 0.02스톱 정도만 움직입니다.

값이 작으면 비례해서 줄어듭니다.

**국소 적용**: 하이라이트와 같이, 현상 패널의 섀도는 가장자리를 지키는 넓은 밝기(반경 80픽셀)에 곡선을 걸고 그 배율을 곱합니다. 그늘진 벽·어두운 숲처럼 어두운 구역 전체는 곡선대로 옮겨지지만 그 안의 질감 명암은 줄거나 과하게 커지지 않습니다. 조정 레이어와 LUT 내보내기에서는 한 픽셀씩 겁니다.

### 화이트 · 블랙 (−100 ~ +100)

곡선의 양끝을 움직여 흰 점·검은 점을 옮깁니다. 가운데로 갈수록 영향이 빠르게 줄어듭니다(세제곱).

| 값 | 뜻 |
|---|---|
| 화이트 +100 | 화면 값 약 0.85 이상이 흰색이 됨 (흰 점을 끌어내림) |
| 화이트 −100 | 흰색(1.0)이 화면 값 0.75로 내려감 |
| 블랙 +100 | 검정(0)이 화면 값 0.10으로 올라감 (물 빠진 검정) |
| 블랙 −100 | 화면 값 약 0.075 이하가 검정이 됨 (검은 점을 끌어올림) |

중간 회색은 ±100에서도 화면 값으로 0.03 이내만 움직입니다.

### 채도 (−100 ~ +100)

| 값 | 뜻 |
|---|---|
| −100 | 흑백 (휘도는 그대로) |
| +100 | 색의 진하기(회색에서 떨어진 정도) 2배 |

### 클래리티 · 구조 (−100 ~ +100)

가장자리를 지키는 필터(가이디드 필터)로 사진의 밝기를 "넓은 흐름"과 "세부"로 나누고, 세부를 (1 + 2 × 값 ÷ 100)배 합니다. +100이면 세부가 3배, −100이면 세부가 반대로 뒤집혀 지워지는 쪽입니다. 아주 어두운 곳(화면 값 0.15 아래)과 아주 밝은 곳(0.85 위)은 덜 겁니다.

- **클래리티**: 반경 120픽셀(원본 기준)의 큰 덩어리 대비
- **구조**: 반경 12픽셀의 잔 질감

전체 밝기와 색은 거의 그대로 두고 국소 대비만 바꿉니다. 방식마다 세기와 채도가 다릅니다: 내추럴(세기 ×1, 채도 조금), 펀치(×1.4, 채도 더), 뉴트럴(×1, 채도 그대로), 클래식(×1.2, 가장자리 보존 약하게).

### 디헤이즈 (0 ~ 100)

다크 채널 방식(He 2009)으로 곳마다 안개의 양을 재고 걷어 냅니다. 100이면 추정한 안개의 80%를 걷습니다(다 걷으면 하늘이 어둡게 뒤집히기 쉬워서). 안개 색을 지정하면 그 색을 기준으로 걷습니다.

### 확인

자체 검사(`DUOCHROME_SELFTEST=1`)의 "슬라이더 정의" 항목이 위 숫자를 확인합니다. 밝기 +100에서 회색 0.18 → 0.36, 대비에서 회색 고정, 하이라이트 −100에서 L 0.85가 절반·+100에서 L 0.83이 0.91·밝은 구역 질감 유지, 섀도 +100에서 L 0.1이 두 배·−100에서 L 0.17이 0.09·어두운 구역 질감 유지가 되는지 봅니다.
