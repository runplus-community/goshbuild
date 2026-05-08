#!/usr/bin/env bash
# =============================================================================
# goshbuild.sh — Pack a Go module into a single self-contained runnable .sh
# Usage: ./goshbuild.sh pack <src_dir> <out_runner.sh>
# Supports: GitHub Actions Ubuntu (primary), macOS (secondary)
# =============================================================================
set -euo pipefail

# =============================================================================
# PORTABILITY HELPERS (packer-side)
# Mirrored in the runner stub so both behave identically on any platform.
# =============================================================================

_sha256_file() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "ERROR: no sha256 tool found (sha256sum or shasum required)" >&2; exit 1
    fi
}

_sha256_str() {
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
        echo "ERROR: no sha256 tool found" >&2; exit 1
    fi
}

_b64_encode() {
    base64 < "$1"   # stdin mode works on both GNU and BSD base64
}

_is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_enable_verbose_logging() {
    local log_file="$1"

    mkdir -p "$(dirname "${log_file}")"
    : > "${log_file}"

    if command -v tee >/dev/null 2>&1; then
        exec > >(tee -a "${log_file}") 2>&1
    else
        exec >> "${log_file}" 2>&1
    fi

    echo "📜 [goshbuild] Transcript → ${log_file}"

    if _is_truthy "${GOSHBUILD_TRACE:-0}"; then
        set -x
    fi
}

_load_tar_excludes() {
    local src_dir="$1"
    local ignore_file="${src_dir}/.goshbuildignore"
    local line=""
    local trimmed=""
    local custom_count=0

    TAR_EXCLUDES=(
        "--exclude=.git"
        "--exclude=bin"
        "--exclude=conversions"
        "--exclude=out"
        "--exclude=_runner_out"
        "--exclude=archive"
        "--exclude=.*"
        "--exclude=dist"
        "--exclude=.goshbuildignore"
        "--exclude=*.goshignore.*"
        "--exclude=*.gitignore.*"
    )

    if [[ ! -f "${ignore_file}" ]]; then
        return
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        case "${trimmed}" in
            ''|\#*)
                continue
                ;;
        esac

        TAR_EXCLUDES+=("--exclude=${trimmed}")
        (( custom_count++ )) || true
    done < "${ignore_file}"

    echo "📄 [goshbuild] Ignore   : ${ignore_file} (${custom_count} custom pattern(s))"
}

_vendor_before_pack() {
    local src_dir="$1"
    local original_go_cache="${GOCACHE:-}"
    local isolated_go_cache=""

    if ! command -v go >/dev/null 2>&1; then
        echo "🔴 [goshbuild] ERROR: go command not found on PATH (required for go mod vendor)" >&2
        exit 1
    fi

    echo "📦 [goshbuild] Vendor   : go mod vendor"
    isolated_go_cache="$(mktemp -d 2>/dev/null || mktemp -d -t goshbuild-gocache)"
    export GOCACHE="${isolated_go_cache}"
    (
        cd "${src_dir}" && go mod vendor
    ) \
        || {
            local vendor_exit=$?
            echo "🔴 [goshbuild] ERROR: go mod vendor failed" >&2
            if [[ -n "${original_go_cache}" ]]; then
                export GOCACHE="${original_go_cache}"
            else
                unset GOCACHE
            fi
            rm -rf "${isolated_go_cache}"
            exit "${vendor_exit}"
        }

    if [[ -n "${original_go_cache}" ]]; then
        export GOCACHE="${original_go_cache}"
    else
        unset GOCACHE
    fi
    rm -rf "${isolated_go_cache}"

    if [[ -d "${src_dir}/vendor" ]]; then
        echo "✅ [goshbuild] Vendor   : ${src_dir}/vendor"
    fi
}

_write_conversion_artifacts() {
    local src_dir="$1"
    local module_name="$2"
    local module_safe="$3"
    local tarball_sha256="$4"
    local tarball_path="$5"
    local payload_b64_path="$6"
    local runner_stub_path="$7"
    local out_runner="$8"
    local out_test="$9"
    local pack_log_path="${10:-}"
    local conversions_dir="${src_dir}/conversions/${module_safe}/${tarball_sha256}"
    local metadata_path="${conversions_dir}/metadata.txt"
    local pack_transcript_path="${conversions_dir}/pack.transcript.raw.log"

    mkdir -p "${conversions_dir}"

    cp "${tarball_path}" "${conversions_dir}/payload.tar.gz"
    cp "${payload_b64_path}" "${conversions_dir}/payload.b64.txt"
    cp "${runner_stub_path}" "${conversions_dir}/runner.stub.sh"
    if [[ -f "${out_runner}" ]]; then
        cp "${out_runner}" "${conversions_dir}/runner.full.sh"
    fi
    if [[ -f "${out_test}" ]]; then
        cp "${out_test}" "${conversions_dir}/runner.test.sh"
    fi
    if [[ -n "${pack_log_path}" && -f "${pack_log_path}" ]]; then
        cp "${pack_log_path}" "${pack_transcript_path}"
    fi

    {
        printf 'module_name=%s\n' "${module_name}"
        printf 'module_safe=%s\n' "${module_safe}"
        printf 'payload_sha256=%s\n' "${tarball_sha256}"
        printf 'source_dir=%s\n' "${src_dir}"
        printf 'runner_path=%s\n' "${out_runner}"
        printf 'test_path=%s\n' "${out_test}"
        if [[ -f "${out_runner}" ]]; then
            printf 'runner_full_copy=%s\n' "${conversions_dir}/runner.full.sh"
        fi
        if [[ -f "${out_test}" ]]; then
            printf 'runner_test_copy=%s\n' "${conversions_dir}/runner.test.sh"
        fi
        if [[ -n "${pack_log_path}" && -f "${pack_log_path}" ]]; then
            printf 'pack_transcript=%s\n' "${pack_transcript_path}"
        fi
    } > "${metadata_path}"

    echo "🗂️ [goshbuild] Conversions → ${conversions_dir}"
    if [[ -n "${pack_log_path}" && -f "${pack_log_path}" ]]; then
        echo "📜 [goshbuild] Transcript  → ${pack_transcript_path}"
    fi
}

_register_pack_in_con() {
    local src_dir="$1"
    local module_name="$2"
    local module_safe="$3"
    local tarball_sha256="$4"
    local out_runner="$5"
    local out_test="$6"
    local pack_log_path="$7"
    local con_base_dir="$8"
    local run_stamp=""
    local run_id=""
    local con_root="${con_base_dir}/.con/${module_safe}/${tarball_sha256}"
    local run_dir=""
    local latest_dir="${con_root}/latest"
    local metadata_path=""
    local latest_metadata_path="${latest_dir}/registration.env"
    local transcript_name="conversation.transcript.raw.log"

    run_stamp="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%dT%H%M%SZ')"
    run_id="${run_stamp}-$$"
    run_dir="${con_root}/runs/${run_id}"
    metadata_path="${run_dir}/registration.env"

    mkdir -p "${run_dir}" "${latest_dir}"

    if [[ -n "${pack_log_path}" && -f "${pack_log_path}" ]]; then
        cp "${pack_log_path}" "${run_dir}/${transcript_name}"
        cp "${pack_log_path}" "${latest_dir}/${transcript_name}"
    fi

    {
        printf 'registered_at_utc=%s\n' "${run_stamp}"
        printf 'run_id=%s\n' "${run_id}"
        printf 'module_name=%s\n' "${module_name}"
        printf 'module_safe=%s\n' "${module_safe}"
        printf 'payload_sha256=%s\n' "${tarball_sha256}"
        printf 'source_dir=%s\n' "${src_dir}"
        printf 'runner_path=%s\n' "${out_runner}"
        printf 'test_path=%s\n' "${out_test}"
        if [[ -n "${pack_log_path}" && -f "${pack_log_path}" ]]; then
            printf 'conversation_transcript=%s\n' "${run_dir}/${transcript_name}"
        fi
    } > "${metadata_path}"

    cp "${metadata_path}" "${latest_metadata_path}"

    echo "🗂️ [goshbuild] .con      → ${run_dir}"
}

# =============================================================================
# RUNNER STUB TEMPLATE
# Embedded verbatim into the generated .sh.
# Placeholders: %%MODULE_SAFE%%  %%TARBALL_SHA256%%
# Base64 payload is appended after the __PAYLOAD_B64__ marker.
# =============================================================================
read -r -d '' RUNNER_STUB <<'STUB_EOF' || true
#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Auto-generated by goshbuild — DO NOT EDIT
# Self-contained Go module runner — works on Linux (GH Actions) and macOS
# ----------------------------------------------------------------------------
set -euo pipefail

# ── Portability helpers ───────────────────────────────────────────────────

# sha256 of a file — supports GNU (sha256sum) and BSD/macOS (shasum)
_sha256_file() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "🔴 [goshbuild] ERROR: no sha256 tool found (sha256sum or shasum required)" >&2; exit 1
    fi
}

# sha256 of a string
_sha256_str() {
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
        echo "🔴 [goshbuild] ERROR: no sha256 tool found" >&2; exit 1
    fi
}

# base64 decode from stdin — GNU uses --decode, BSD/macOS uses -D
_b64_decode() {
    if base64 --decode /dev/null &>/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

_is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_enable_verbose_logging() {
    local log_file="$1"

    mkdir -p "$(dirname "${log_file}")"
    : > "${log_file}"

    if command -v tee >/dev/null 2>&1; then
        exec > >(tee -a "${log_file}") 2>&1
    else
        exec >> "${log_file}" 2>&1
    fi

    echo "📜 [goshbuild] Transcript → ${log_file}"

    if _is_truthy "${GOSHBUILD_TRACE:-0}"; then
        set -x
    fi
}

# Map uname -m kernel names to Go arch names.
# Without this, x86_64 in the cache key would never match go env GOARCH=amd64.
_resolve_goarch() {
    case "${1:-}" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i686)     echo "386"   ;;
        armv7l|armv6l) echo "arm"   ;;
        *)             echo "${1}"  ;;
    esac
}

# Clear a directory's contents before re-extracting sources.
# This avoids stale files surviving across payload changes.
_clear_dir_contents() {
    local dir="$1"
    local entries=()

    mkdir -p "${dir}"
    shopt -s dotglob nullglob
    entries=( "${dir}"/* )
    shopt -u dotglob nullglob

    if (( ${#entries[@]} > 0 )); then
        rm -rf "${entries[@]}"
    fi
}

# ── 1. Identity & home ────────────────────────────────────────────────────
MODULE_SAFE="%%MODULE_SAFE%%"
PAYLOAD_SHA256="%%TARBALL_SHA256%%"   # sha256 of the embedded tar.gz;
                                       # any source change → new hash → rebuild

# MMM_HOME lets CI pin the cache to a persistent volume between runs.
BASE_HOME="${MMM_HOME:-${TMPDIR:-/tmp}}"
APP_HOME="${BASE_HOME}/goshbuild/${MODULE_SAFE}"
GOCACHE="${APP_HOME}/gocache"

SRC_DIR="${APP_HOME}/src"
BIN_DIR="${APP_HOME}/bin"
OUT_DIR="${APP_HOME}/out"
DECODE_TMP="${APP_HOME}/payload_verify.tar.gz"  # temp file used for checksum check

mkdir -p "${SRC_DIR}" "${BIN_DIR}" "${OUT_DIR}" "${GOCACHE}"
export GOCACHE

# ── 2. Cache key ──────────────────────────────────────────────────────────
# Four-part key — all must match or binary is rebuilt:
#   module_safe → isolates projects sharing the same MMM_HOME
#   GOOS/GOARCH → arch/OS mismatch → rebuild
#   go version  → toolchain upgrade → rebuild
#   payload sha → source change → rebuild
GOOS="${GOOS:-$(go env GOOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')}"

if _raw_arch="$(go env GOARCH 2>/dev/null)"; then
    GOARCH="${GOARCH:-${_raw_arch}}"
else
    # Fall back to uname -m and map to Go arch names
    GOARCH="${GOARCH:-$(_resolve_goarch "$(uname -m)")}"
fi

GO_VERSION="$(go version 2>/dev/null | awk '{print $3}' || echo 'unknown')"

CACHE_KEY="${MODULE_SAFE}__${GOOS}_${GOARCH}__${GO_VERSION}__${PAYLOAD_SHA256}"
CACHE_KEY_HASH="$(_sha256_str "${CACHE_KEY}")"

BINARY="${BIN_DIR}/${CACHE_KEY_HASH}/app"

if _is_truthy "${GOSHBUILD_VERBOSE:-0}"; then
    RUNNER_LOG_DIR="${GOSHBUILD_LOG_DIR:-${APP_HOME}/logs}"
    _enable_verbose_logging "${RUNNER_LOG_DIR}/runner-${CACHE_KEY_HASH}-$$.log"
fi

# ── 3. Build (cache miss path) ────────────────────────────────────────────
if [[ ! -x "${BINARY}" ]]; then
    echo "🔨 [goshbuild] Cache miss — building ${MODULE_SAFE} (${GOOS}/${GOARCH}, ${GO_VERSION})" >&2

    # 3a. Find the payload marker line
    PAYLOAD_LINE="$(grep -n '^__PAYLOAD_B64__$' "$0" | cut -d: -f1)"
    if [[ -z "${PAYLOAD_LINE}" ]]; then
        echo "🔴 [goshbuild] ERROR: payload marker not found in runner script" >&2
        exit 1
    fi
    PAYLOAD_START=$(( PAYLOAD_LINE + 1 ))

    # 3b. Decode into a temp file, then verify sha256 BEFORE extracting.
    #     If the runner was truncated or corrupted, we fail fast with a clear message
    #     rather than letting tar produce a confusing partial extraction.
    tail -n "+${PAYLOAD_START}" "$0" | _b64_decode > "${DECODE_TMP}"

    ACTUAL_SHA="$(_sha256_file "${DECODE_TMP}")"
    if [[ "${ACTUAL_SHA}" != "${PAYLOAD_SHA256}" ]]; then
        echo "🔴 [goshbuild] ERROR: payload checksum mismatch — runner may be corrupted!" >&2
        echo "   expected : ${PAYLOAD_SHA256}" >&2
        echo "   actual   : ${ACTUAL_SHA}" >&2
        rm -f "${DECODE_TMP}"
        exit 1
    fi
    echo "✅ [goshbuild] Payload checksum verified (${ACTUAL_SHA:0:12}…)" >&2

    # 3c. Clear any previously extracted tree so deleted files do not linger.
    _clear_dir_contents "${SRC_DIR}"

    # 3d. Unpack verified tarball
    tar -xz -C "${SRC_DIR}" --strip-components=1 < "${DECODE_TMP}"
    rm -f "${DECODE_TMP}"

    # 3e. Compile
    mkdir -p "$(dirname "${BINARY}")"
    echo "⚙️  [goshbuild] go build → ${BINARY}" >&2
    (cd "${SRC_DIR}" && go build -o "${BINARY}" .) \
        || { echo "🔴 [goshbuild] ERROR: go build failed" >&2; exit 1; }

    echo "✅ [goshbuild] Build complete → ${BINARY}" >&2
else
    echo "⚡ [goshbuild] Cache hit → ${BINARY}" >&2
fi

# ── 4. Exec — forward ALL CLI args seamlessly ─────────────────────────────
# exec replaces this shell process with the Go binary — no PID wrapper,
# signals propagate directly, exit codes are exact.
# "$@" preserves every argument exactly as the caller passed them.
exec "${BINARY}" "$@"

# (Never reached — exec replaced this process)
__PAYLOAD_B64__
STUB_EOF

# =============================================================================
# TEST SCRIPT TEMPLATE
# Generated alongside the runner as <out_runner>.test.sh
# Placeholders: %%MODULE_SAFE%%  %%MODULE_NAME%%  %%RUNNER_PATH%%
# =============================================================================
read -r -d '' TEST_STUB <<'TEST_EOF' || true
#!/usr/bin/env bash
# =============================================================================
# Auto-generated by goshbuild — acceptance tests for %%RUNNER_PATH%%
# Run:  bash %%RUNNER_PATH%%.test.sh
# =============================================================================
set -euo pipefail

RUNNER="%%RUNNER_PATH%%"
MODULE_NAME="%%MODULE_NAME%%"
MODULE_SAFE="%%MODULE_SAFE%%"

PASS=0; FAIL=0
_pass() { echo "  ✓ $*"; (( PASS++ )) || true; }
_fail() { echo "  ✗ $*" >&2; (( FAIL++ )) || true; }

assert_exit() {
    local desc="$1" want="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    [[ "${got}" -eq "${want}" ]] && _pass "${desc} (exit ${got})" \
                                 || _fail "${desc}: expected exit ${want}, got ${got}"
}

assert_file_exists() {
    local desc="$1" path="$2"
    [[ -e "${path}" ]] && _pass "${desc}" || _fail "${desc}: '${path}' not found"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " goshbuild acceptance tests"
echo " module : ${MODULE_NAME}"
echo " runner : ${RUNNER}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# T-01  Runner file exists and is executable
echo ""; echo "[T-01] Runner file"
assert_file_exists "runner .sh exists" "${RUNNER}"
[[ -x "${RUNNER}" ]] && _pass "runner is executable" || _fail "runner is not executable"

# T-02  go toolchain available
echo ""; echo "[T-02] go toolchain"
assert_exit "go is on PATH" 0 go version

# T-03  First run → cache miss + build
echo ""; echo "[T-03] First run — cache miss & build"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT

FIRST_OUT="$(MMM_HOME="${TEST_HOME}" "${RUNNER}" 2>&1 || true)"
echo "${FIRST_OUT}" | grep -q "Cache miss" \
    && _pass "first run reported cache miss" \
    || _fail "expected 'Cache miss'; got: ${FIRST_OUT}"
echo "${FIRST_OUT}" | grep -q "Build complete" \
    && _pass "first run reported build complete" \
    || _fail "expected 'Build complete'; got: ${FIRST_OUT}"

# T-04  Second run same MMM_HOME → cache hit, no rebuild
echo ""; echo "[T-04] Second run — cache hit"
SECOND_OUT="$(MMM_HOME="${TEST_HOME}" "${RUNNER}" 2>&1 || true)"
echo "${SECOND_OUT}" | grep -q "Cache hit" \
    && _pass "second run reported cache hit" \
    || _fail "expected 'Cache hit'; got: ${SECOND_OUT}"
echo "${SECOND_OUT}" | grep -qv "Build complete" \
    && _pass "second run did not rebuild" \
    || _fail "unexpected 'Build complete' on second run"

# T-05  Fresh MMM_HOME → cache miss again
echo ""; echo "[T-05] Fresh MMM_HOME → cache miss"
TEST_HOME2="$(mktemp -d)"
FRESH_OUT="$(MMM_HOME="${TEST_HOME2}" "${RUNNER}" 2>&1 || true)"
echo "${FRESH_OUT}" | grep -q "Cache miss" \
    && _pass "fresh home caused cache miss" \
    || _fail "expected cache miss with fresh home; got: ${FRESH_OUT}"
rm -rf "${TEST_HOME2}"

# T-06  Payload checksum verified on first build
echo ""; echo "[T-06] Payload checksum verification"
echo "${FIRST_OUT}" | grep -q "Payload checksum verified" \
    && _pass "checksum verified message present" \
    || _fail "expected checksum verification in output; got: ${FIRST_OUT}"

# T-07  Arg forwarding
echo ""; echo "[T-07] Arg forwarding"
SENTINEL="goshbuild_arg_test_$$"
ARG_OUT="$(MMM_HOME="${TEST_HOME}" "${RUNNER}" --goshbuild-test "${SENTINEL}" 2>&1 || true)"
if echo "${ARG_OUT}" | grep -q "${SENTINEL}"; then
    _pass "sentinel arg echoed back by binary"
elif echo "${ARG_OUT}" | grep -qiE "unknown|flag|unrecognized|invalid"; then
    _pass "binary received and rejected unknown flag (forwarding confirmed)"
else
    _fail "could not confirm arg forwarding; output: ${ARG_OUT}"
fi

# T-08  Exit-code forwarding
echo ""; echo "[T-08] Exit-code forwarding"
BINARY_PATH="$(find "${TEST_HOME}/goshbuild/${MODULE_SAFE}/bin" -name 'app' 2>/dev/null | head -n 1)"
if [[ -z "${BINARY_PATH}" ]]; then
    _fail "could not locate compiled binary under MMM_HOME for exit-code comparison"
else
    RUNNER_EXIT=0
    BINARY_EXIT=0
    MMM_HOME="${TEST_HOME}" "${RUNNER}" --goshbuild-test "${SENTINEL}" >/dev/null 2>&1 || RUNNER_EXIT=$?
    "${BINARY_PATH}" --goshbuild-test "${SENTINEL}" >/dev/null 2>&1 || BINARY_EXIT=$?
    [[ "${RUNNER_EXIT}" -eq "${BINARY_EXIT}" ]] \
        && _pass "runner exit code matches built binary (exit ${RUNNER_EXIT})" \
        || _fail "runner exit ${RUNNER_EXIT} did not match built binary exit ${BINARY_EXIT}"
fi

# T-09  Cache dir layout
echo ""; echo "[T-09] Cache directory layout"
BIN_COUNT="$(find "${TEST_HOME}/goshbuild/${MODULE_SAFE}/bin" -name 'app' 2>/dev/null | wc -l | tr -d ' ')"
[[ "${BIN_COUNT}" -ge 1 ]] \
    && _pass "compiled binary found under MMM_HOME/goshbuild/${MODULE_SAFE}/bin/" \
    || _fail "no compiled binary found under expected path"

# T-10  Payload marker present
echo ""; echo "[T-10] Payload integrity"
grep -q '^__PAYLOAD_B64__$' "${RUNNER}" \
    && _pass "__PAYLOAD_B64__ marker present in runner" \
    || _fail "__PAYLOAD_B64__ marker missing — runner is malformed"

# T-11  Runner bash syntax check
echo ""; echo "[T-11] Runner syntax"
bash -n "${RUNNER}" \
    && _pass "runner passes bash -n syntax check" \
    || _fail "runner failed bash -n syntax check"

# T-12  Corruption detection — tamper with payload, expect checksum error
echo ""; echo "[T-12] Corruption detection"
CORRUPT_RUNNER="$(mktemp)"
cp "${RUNNER}" "${CORRUPT_RUNNER}"
chmod +x "${CORRUPT_RUNNER}"
MARKER_LINE="$(grep -n '^__PAYLOAD_B64__$' "${CORRUPT_RUNNER}" | cut -d: -f1)"
# IMPORTANT: base64 output may not contain a predictable character on any
# particular line (wrapping at ~76 chars). So we corrupt the *first non-empty*
# payload line by flipping its first character deterministically.
TMP_CORRUPT="$(mktemp)"
awk -v m="${MARKER_LINE}" '
  NR<=m { print; next }
  (!mod && length($0)>0) {
    c=substr($0,1,1);
    r=(c=="A"?"B":"A");
    $0=r substr($0,2);
    mod=1;
  }
  { print }
  END { if(!mod) exit 2 }
' "${CORRUPT_RUNNER}" > "${TMP_CORRUPT}" \
  && mv "${TMP_CORRUPT}" "${CORRUPT_RUNNER}" \
  || { rm -f "${TMP_CORRUPT}"; true; }
chmod +x "${CORRUPT_RUNNER}" 2>/dev/null || true
CORRUPT_HOME="$(mktemp -d)"
CORRUPT_OUT="$(MMM_HOME="${CORRUPT_HOME}" "${CORRUPT_RUNNER}" 2>&1 || true)"
echo "${CORRUPT_OUT}" | grep -qiE "checksum mismatch|corrupted" \
    && _pass "corrupted runner detected and rejected" \
    || _fail "expected checksum mismatch error; got: ${CORRUPT_OUT}"
rm -rf "${CORRUPT_HOME}" "${CORRUPT_RUNNER}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$(( PASS + FAIL ))
echo " Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
TEST_EOF

# =============================================================================
# PACKER LOGIC
# =============================================================================

usage() {
    cat >&2 <<'USAGE'
Usage:
  goshbuild.sh                 # auto-pack current module → ./<module_safe>.run.sh
  goshbuild.sh pack            # same as above
  goshbuild.sh pack <src_dir>  # auto-pack module at src_dir → <src_dir>/<module_safe>.run.sh
  goshbuild.sh pack <src_dir> <out_runner.sh>

Notes:
  - module_safe is derived from 'module ...' in go.mod by replacing '/' and '.' with '_'
  - A .test.sh is generated alongside the runner: <out_runner.sh>.test.sh
  - go mod vendor is always executed before packing so vendor/ is included in the payload
  - Each pack run is registered under <goshbuild_dir>/.con/<module_safe>/<payload_sha256>/runs/<run_id>/
  - Raw conversion artifacts and a complete pack transcript are written under <src_dir>/conversions/<module_safe>/<payload_sha256>/
  - Set GOSHBUILD_VERBOSE=1 to persist generated runner logs; GOSHBUILD_TRACE=1 adds shell tracing
  - Optional: add <src_dir>/.goshbuildignore to append tar --exclude patterns
USAGE
    exit 1
}

# ---- Parse args (simple, auto-detect) ----
CMD="${1:-pack}"
SRC_ARG=""
OUT_ARG=""

if [[ "${1:-}" == "" ]]; then
    CMD="pack"
elif [[ "${1:-}" == "pack" ]]; then
    CMD="pack"
    SRC_ARG="${2:-}"
    OUT_ARG="${3:-}"
else
    # ultra-simple convenience: if user passes a directory as first arg, treat it as src_dir
    if [[ -d "${1}" ]]; then
        CMD="pack"
        SRC_ARG="${1}"
        OUT_ARG="${2:-}"
    else
        usage
    fi
fi

if [[ "${CMD}" != "pack" ]]; then
    usage
fi

# default src_dir is current directory
if [[ -z "${SRC_ARG}" ]]; then
    SRC_ARG="."
fi

SRC_DIR="$(cd "${SRC_ARG}" && pwd)"
PACKER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -d "${SRC_DIR}" ]]        || { echo "ERROR: '${SRC_DIR}' is not a directory" >&2; exit 1; }
[[ -f "${SRC_DIR}/go.mod" ]] || { echo "ERROR: no go.mod found in '${SRC_DIR}'" >&2; exit 1; }

MODULE_NAME="$(grep '^module ' "${SRC_DIR}/go.mod" | awk '{print $2}' | head -1)"
[[ -n "${MODULE_NAME}" ]] || { echo "ERROR: could not parse module name from go.mod" >&2; exit 1; }

# A) Naming rule: derive output name from module path (go.mod)
MODULE_SAFE="$(printf '%s' "${MODULE_NAME}" | tr '/.' '__')"

# Default out_runner is <src_dir>/<module_safe>.run.sh
if [[ -z "${OUT_ARG}" ]]; then
    OUT_RUNNER="${SRC_DIR}/${MODULE_SAFE}.run.sh"
else
    # Resolve output path portably (realpath -m is GNU-only)
    mkdir -p "$(dirname "${OUT_ARG}")"
    OUT_RUNNER="$(cd "$(dirname "${OUT_ARG}")" && pwd)/$(basename "${OUT_ARG}")"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
PACK_LOG_FILE="${WORK_DIR}/pack.transcript.raw.log"
_enable_verbose_logging "${PACK_LOG_FILE}"

echo "📦 [goshbuild] Module   : ${MODULE_NAME}"
echo "📦 [goshbuild] Safe ID  : ${MODULE_SAFE}"
echo "📦 [goshbuild] Source   : ${SRC_DIR}"
echo "📦 [goshbuild] Output   : ${OUT_RUNNER}"

_vendor_before_pack "${SRC_DIR}"

TARBALL="${WORK_DIR}/payload.tar.gz"
PAYLOAD_B64_FILE="${WORK_DIR}/payload.b64.txt"
RESOLVED_RUNNER_STUB="${WORK_DIR}/runner.stub.sh"

_load_tar_excludes "${SRC_DIR}"

tar -czf "${TARBALL}" \
    "${TAR_EXCLUDES[@]}" \
    -C "$(dirname "${SRC_DIR}")" \
    "$(basename "${SRC_DIR}")"

TARBALL_SHA256="$(_sha256_file "${TARBALL}")"
echo "🔑 [goshbuild] Payload SHA256 : ${TARBALL_SHA256}"

_b64_encode "${TARBALL}" > "${PAYLOAD_B64_FILE}"

printf '%s\n' "${RUNNER_STUB}" \
    | sed \
        -e "s|%%MODULE_SAFE%%|${MODULE_SAFE}|g" \
        -e "s|%%TARBALL_SHA256%%|${TARBALL_SHA256}|g" \
    > "${RESOLVED_RUNNER_STUB}"

OUT_TEST="${OUT_RUNNER}.test.sh"

# Write runner: stub (placeholders substituted) + appended base64 payload
{
    cat "${RESOLVED_RUNNER_STUB}"
    cat "${PAYLOAD_B64_FILE}"
} > "${OUT_RUNNER}"

chmod +x "${OUT_RUNNER}"
echo "✅ [goshbuild] Runner  → ${OUT_RUNNER}"
echo "   Run with: ${OUT_RUNNER} --help"

# Write test script
printf '%s\n' "${TEST_STUB}" \
    | sed \
        -e "s|%%MODULE_SAFE%%|${MODULE_SAFE}|g" \
        -e "s|%%MODULE_NAME%%|${MODULE_NAME}|g" \
        -e "s|%%RUNNER_PATH%%|${OUT_RUNNER}|g" \
    > "${OUT_TEST}"

chmod +x "${OUT_TEST}"
echo "🧪 [goshbuild] Tests   → ${OUT_TEST}"
echo "   Run with: bash ${OUT_TEST}"

_write_conversion_artifacts \
    "${SRC_DIR}" \
    "${MODULE_NAME}" \
    "${MODULE_SAFE}" \
    "${TARBALL_SHA256}" \
    "${TARBALL}" \
    "${PAYLOAD_B64_FILE}" \
    "${RESOLVED_RUNNER_STUB}" \
    "${OUT_RUNNER}" \
    "${OUT_TEST}" \
    "${PACK_LOG_FILE}"

_register_pack_in_con \
    "${SRC_DIR}" \
    "${MODULE_NAME}" \
    "${MODULE_SAFE}" \
    "${TARBALL_SHA256}" \
    "${OUT_RUNNER}" \
    "${OUT_TEST}" \
    "${PACK_LOG_FILE}" \
    "${PACKER_HOME}"
