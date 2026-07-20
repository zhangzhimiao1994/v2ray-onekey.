#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/src/v2ray-onekey.sh.in"

render() (
  local variant="$1" destination="$2" mode="${3:-write}" temp=""

  if [[ "$mode" == "check" ]]; then
    sed "s/@INSTALLER_VARIANT@/$variant/g" "$TEMPLATE" | cmp -s - "$destination" || {
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
  sed "s/@INSTALLER_VARIANT@/$variant/g" "$TEMPLATE" >"$temp"
  chmod 755 -- "$temp"
  mv -f -- "$temp" "$destination"
  temp=""
)

build_all() {
  local mode="${1:-write}"
  render new "$ROOT_DIR/outputs/v2ray-onekey-new.sh" "$mode"
  render upgrade-cf "$ROOT_DIR/outputs/v2ray-onekey-upgrade-cf.sh" "$mode"
}

if (( $# == 0 )); then
  build_all write
elif (( $# == 1 )) && [[ "$1" == "--check" ]]; then
  build_all check
else
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 2
fi
