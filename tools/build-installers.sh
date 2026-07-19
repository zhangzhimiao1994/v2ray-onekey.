#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/src/v2ray-onekey.sh.in"
OUTPUT="$ROOT_DIR/outputs/v2ray-onekey-new.sh"

render() (
  local destination="$1" mode="${2:-write}" temp=""

  if [[ "$mode" == "check" ]]; then
    sed 's/@INSTALLER_VARIANT@/new/g' "$TEMPLATE" | cmp -s - "$destination" || {
      printf 'generated artifact is stale: %s\n' "$destination" >&2
      return 1
    }
    return 0
  fi

  trap 'rm -f -- "$temp"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir -p "$(dirname "$destination")"
  temp="$(mktemp "${destination}.tmp.XXXXXX")"
  sed 's/@INSTALLER_VARIANT@/new/g' "$TEMPLATE" >"$temp"
  chmod 755 -- "$temp"
  mv -f -- "$temp" "$destination"
  temp=""
)

if (( $# == 0 )); then
  render "$OUTPUT" write
elif (( $# == 1 )) && [[ "$1" == "--check" ]]; then
  render "$OUTPUT" check
else
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 2
fi
