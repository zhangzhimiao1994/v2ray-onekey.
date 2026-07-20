#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fresh="$ROOT_DIR/outputs/v2ray-onekey-new.sh"

"$ROOT_DIR/tools/build-installers.sh" --check

set +e
extra_arg_output="$("$ROOT_DIR/tools/build-installers.sh" --check unexpected 2>&1)"
extra_arg_status=$?
set -e
[[ "$extra_arg_status" -eq 2 ]]
grep -Fqx "usage: $ROOT_DIR/tools/build-installers.sh [--check]" <<<"$extra_arg_output"

set +e
empty_arg_output="$("$ROOT_DIR/tools/build-installers.sh" "" 2>&1)"
empty_arg_status=$?
set -e
[[ "$empty_arg_status" -eq 2 ]]
grep -Fqx "usage: $ROOT_DIR/tools/build-installers.sh [--check]" <<<"$empty_arg_output"

fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/src" "$fixture_root/tools" "$fixture_root/outputs" \
  "$fixture_root/fake-bin" "$fixture_root/readonly-bin" "$fixture_root/tmp"
cp "$ROOT_DIR/src/v2ray-onekey.sh.in" "$fixture_root/src/v2ray-onekey.sh.in"
cp "$ROOT_DIR/tools/build-installers.sh" "$fixture_root/tools/build-installers.sh"
chmod 755 "$fixture_root/tools/build-installers.sh"

fixture_builder="$fixture_root/tools/build-installers.sh"
fixture_output="$fixture_root/outputs/v2ray-onekey-new.sh"
fixture_snapshot="$fixture_root/output.snapshot"

"$fixture_builder"
[[ -x "$fixture_output" ]]
grep -Fq 'INSTALLER_VARIANT="new"' "$fixture_output"
cp "$fixture_output" "$fixture_snapshot"
"$fixture_builder"
cmp -s "$fixture_snapshot" "$fixture_output"

cat >"$fixture_root/readonly-bin/mkdir" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    "$READONLY_ROOT"/*)
      printf 'repository mkdir attempted: %s\n' "$argument" >&2
      exit 91
      ;;
  esac
done
exec "$REAL_MKDIR" "$@"
EOF
cat >"$fixture_root/readonly-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  "$READONLY_ROOT"/*)
    printf 'repository mktemp attempted: %s\n' "$1" >&2
    exit 92
    ;;
esac
exec "$REAL_MKTEMP" "$@"
EOF
chmod 755 "$fixture_root/readonly-bin/mkdir" "$fixture_root/readonly-bin/mktemp"
chmod -R a-w "$fixture_root/src" "$fixture_root/outputs"
set +e
readonly_output="$(
  READONLY_ROOT="$fixture_root" REAL_MKDIR="$(command -v mkdir)" \
    REAL_MKTEMP="$(command -v mktemp)" PATH="$fixture_root/readonly-bin:$PATH" \
    "$fixture_builder" --check 2>&1
)"
readonly_status=$?
set -e
chmod -R u+w "$fixture_root/src" "$fixture_root/outputs"
if [[ "$readonly_status" -ne 0 ]]; then
  printf 'read-only check failed: %s\n' "$readonly_output" >&2
  exit 1
fi
cmp -s "$fixture_snapshot" "$fixture_output"

printf '# stale\n' >>"$fixture_output"
cp "$fixture_output" "$fixture_snapshot"
set +e
stale_output="$("$fixture_builder" --check 2>&1)"
stale_status=$?
set -e
[[ "$stale_status" -eq 1 ]]
grep -Fqx "generated artifact is stale: $fixture_output" <<<"$stale_output"
cmp -s "$fixture_snapshot" "$fixture_output"

"$fixture_builder"
cp "$fixture_output" "$fixture_snapshot"
cat >"$fixture_root/fake-bin/sed" <<'EOF'
#!/usr/bin/env bash
printf 'partial render\n'
exit 23
EOF
chmod 755 "$fixture_root/fake-bin/sed"
set +e
PATH="$fixture_root/fake-bin:$PATH" TMPDIR="$fixture_root/tmp" \
  "$fixture_builder" >/dev/null 2>&1
render_failure_status=$?
set -e
[[ "$render_failure_status" -ne 0 ]]
cmp -s "$fixture_snapshot" "$fixture_output"
if compgen -G "$fixture_output.tmp.*" >/dev/null ||
  compgen -G "$fixture_root/tmp/*" >/dev/null; then
  printf 'render failure left a temporary file\n' >&2
  exit 1
fi

[[ -x "$fresh" ]]
head -n 1 "$fresh" | grep -Fqx '#!/usr/bin/env bash'
grep -Fq 'INSTALLER_VARIANT="new"' "$fresh"
if grep -Fq '@INSTALLER_VARIANT@' "$fresh"; then
  printf 'unexpanded installer variant\n' >&2
  exit 1
fi
if grep -Eiq -- '--reality-|make_reality_link|xtls-rprx-vision|security=reality|"tag"[[:space:]]*:[[:space:]]*"reality-in"' "$fresh"; then
  printf 'retired REALITY implementation remains in fresh installer\n' >&2
  exit 1
fi
bash -n "$fresh"
printf 'PASS: generated fresh installer is current\n'
