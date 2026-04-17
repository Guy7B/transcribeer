#!/usr/bin/env bash
# Convert an ivrit-ai Hebrew Whisper model to CoreML format for use with WhisperKit.
#
# Usage:
#   ./scripts/convert-ivrit-ai.sh [turbo|full] <hf-username>
#
# Requirements:
#   - ~16 GB RAM free (large-v3 full); ~8 GB (turbo)
#   - HuggingFace CLI authenticated: huggingface-cli login
#   - uv installed: brew install uv
#
# After conversion, add to ~/.transcribeer/config.toml:
#   [transcription]
#   model = "ivrit-ai_whisper-large-v3-turbo"
#   model_repo = "<hf-username>/ivrit-ai-whisper-large-v3-turbo-coreml"
#   language = "he"
#
# Or in the app: Settings → Transcription → select ivrit-ai model, paste the repo name.

set -euo pipefail

VARIANT="${1:-turbo}"
HF_USER="${2:-}"

if [[ -z "$HF_USER" ]]; then
  echo "Usage: $0 [turbo|full] <hf-username>"
  exit 1
fi

if [[ "$VARIANT" == "turbo" ]]; then
  MODEL_ID="ivrit-ai/whisper-large-v3-turbo"
  REPO_NAME="ivrit-ai-whisper-large-v3-turbo-coreml"
else
  MODEL_ID="ivrit-ai/whisper-large-v3"
  REPO_NAME="ivrit-ai-whisper-large-v3-coreml"
fi

OUTPUT_DIR="./ivrit-ai-coreml-${VARIANT}"

echo "==> Cloning whisperkittools"
if [[ ! -d "whisperkittools" ]]; then
  git clone https://github.com/argmaxinc/whisperkittools
fi
cd whisperkittools

echo "==> Setting up Python environment"
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"

echo "==> Converting ${MODEL_ID} → CoreML (this takes 20–40 min)"
python -m whisperkit.convert \
  --model-version "${MODEL_ID}" \
  --output-dir "../${OUTPUT_DIR}" \
  --encoder-compute-units cpuAndNeuralEngine \
  --decoder-compute-units cpuAndNeuralEngine

cd ..

echo "==> Uploading to HuggingFace: ${HF_USER}/${REPO_NAME}"
huggingface-cli repo create "${REPO_NAME}" --type model --yes || true
huggingface-cli upload "${HF_USER}/${REPO_NAME}" "./${OUTPUT_DIR}"

echo ""
echo "Done! Model repo: ${HF_USER}/${REPO_NAME}"
echo ""
echo "Add to ~/.transcribeer/config.toml:"
echo "  [transcription]"
if [[ "$VARIANT" == "turbo" ]]; then
  echo "  model = \"ivrit-ai_whisper-large-v3-turbo\""
else
  echo "  model = \"ivrit-ai_whisper-large-v3\""
fi
echo "  model_repo = \"${HF_USER}/${REPO_NAME}\""
echo "  language = \"he\""
