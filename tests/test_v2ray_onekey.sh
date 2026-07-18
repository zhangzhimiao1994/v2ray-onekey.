#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/outputs/v2ray-onekey.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'V2RAY_ONEKEY_SOURCE_ONLY' "$SCRIPT" || fail "source-only guard is missing"
printf 'PASS: source-only guard exists\n'
