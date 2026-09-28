#!/bin/bash
# Duochrome AI 엔진 설치. Duochrome이 직접 실행하고, "@@단계 n/N 설명" 줄로 진행을 알린다.
# 설치 위치: ~/Library/Application Support/Duochrome/AI (ComfyUI + 파이썬 환경 + 모델). 창은 띄우지 않는다.
# 이미 받은 것은 건너뛰고, 끊긴 내려받기는 이어서 받는다.
set -uo pipefail
ROOT="${DUOCHROME_AI_ROOT:-$HOME/Library/Application Support/Duochrome/AI}"
COMFY="$ROOT/ComfyUI"
UV="${UV:-$HOME/.local/bin/uv}"
TOTAL=13
step() { echo "@@단계 $1/$TOTAL $2"; }
fail() { echo "@@실패 $1"; exit 1; }

mkdir -p "$ROOT" || fail "설치 폴더를 만들 수 없음"

step 1 "파이썬 도구 준비"
if [ ! -x "$UV" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null 2>&1 || fail "파이썬 도구(uv) 설치 실패"
  UV="$HOME/.local/bin/uv"
fi
"$UV" python install 3.11 >/dev/null 2>&1 || fail "파이썬 3.11 설치 실패"

step 2 "ComfyUI 엔진 내려받기"
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" pull --ff-only -q >/dev/null 2>&1 || true
else
  git clone --depth 1 -q https://github.com/comfyanonymous/ComfyUI "$COMFY" || fail "엔진 내려받기 실패"
fi

step 3 "파이썬 환경 만들기"
[ -x "$COMFY/.venv/bin/python" ] || "$UV" venv -q -p 3.11 "$COMFY/.venv" || fail "파이썬 환경 만들기 실패"
PY="$COMFY/.venv/bin/python"

step 4 "계산 라이브러리 설치 (가장 오래 걸림)"
"$UV" pip install -q -p "$PY" torch torchvision torchaudio || fail "계산 라이브러리 설치 실패"

step 5 "엔진 부품 설치"
"$UV" pip install -q -p "$PY" -r "$COMFY/requirements.txt" || fail "엔진 부품 설치 실패"

step 6 "지우기·채우기 부품 설치"
NODE="$COMFY/custom_nodes/comfyui-inpaint-nodes"
if [ -d "$NODE/.git" ]; then git -C "$NODE" pull --ff-only -q >/dev/null 2>&1 || true
else git clone --depth 1 -q https://github.com/Acly/comfyui-inpaint-nodes "$NODE" || fail "지우기 부품 내려받기 실패"; fi
[ -f "$NODE/requirements.txt" ] && "$UV" pip install -q -p "$PY" -r "$NODE/requirements.txt" >/dev/null 2>&1
"$UV" pip install -q -p "$PY" opencv-python-headless spandrel >/dev/null 2>&1

# 내려받기: 이미 있으면 건너뛰고, 끊겼으면 이어 받는다
get() {  # 주소 저장경로
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if [ -s "$out" ] && [ ! -f "$out.part" ]; then return 0; fi
  touch "$out.part"
  curl -L --fail --retry 3 -C - -s -o "$out" "$url" || { echo "@@경고 내려받기 실패: $(basename "$out")"; return 1; }
  rm -f "$out.part"
}

step 7 "지우기 모델 (약 200MB)"
get "https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt" "$COMFY/models/inpaint/big-lama.pt"

step 8 "채우기 보조 모델 (약 1.3GB)"
get "https://huggingface.co/lllyasviel/fooocus_inpaint/resolve/main/fooocus_inpaint_head.pth" "$COMFY/models/inpaint/fooocus_inpaint_head.pth"
get "https://huggingface.co/lllyasviel/fooocus_inpaint/resolve/main/inpaint_v26.fooocus.patch" "$COMFY/models/inpaint/inpaint_v26.fooocus.patch"

step 9 "빠른 생성 보조 모델 (약 400MB)"
get "https://huggingface.co/ByteDance/SDXL-Lightning/resolve/main/sdxl_lightning_8step_lora.safetensors" "$COMFY/models/loras/sdxl_lightning_8step_lora.safetensors"

step 10 "노이즈 제거·확대 모델 (약 140MB)"
get "https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth" "$COMFY/models/upscale_models/scunet_color_real_psnr.pth"
get "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" "$COMFY/models/upscale_models/RealESRGAN_x2plus.pth"

step 11 "사진 생성 모델 (약 6.6GB)"
CK="$COMFY/models/checkpoints/RealVisXL_V5.0_fp16.safetensors"
# 구글 드라이브는 파일을 통째로 받은 뒤에야 복사가 시작돼 오래 멈춘 것처럼 보였다 → 공식 배포처에서 바로 받는다
get "https://huggingface.co/SG161222/RealVisXL_V5.0/resolve/main/RealVisXL_V5.0_fp16.safetensors" "$CK" || fail "사진 생성 모델을 받지 못함"

step 12 "반사 제거 모델 (약 2.5GB)"
XR="$ROOT/xreflection"
if [ -d "$XR/.git" ]; then git -C "$XR" pull --ff-only -q >/dev/null 2>&1 || true
else git clone --depth 1 -q https://github.com/hainuo-wang/XReflection "$XR" || echo "@@경고 반사 제거 코드 내려받기 실패"; fi
"$UV" pip install -q -p "$PY" timm >/dev/null 2>&1
get "https://checkpoints.mingjia.li/dsit-26.6959.ckpt" "$ROOT/reflection/dsit-26.6959.ckpt"

step 13 "확인"
"$PY" -c "import torch; assert torch.backends.mps.is_available()" || fail "그래픽 가속(MPS)을 쓸 수 없음"
echo ok > "$ROOT/ready"
echo "@@끝"
