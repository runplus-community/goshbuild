#!/usr/bin/env bash
# test_goshbuild.sh
# Higher-order bundle script for the goshbuild demo app.
# It uses the parent packer from the repo root, keeps demo-app source-only,
# and writes the generated runner plus acceptance test into
# dist-demo-app/ for review.
#
# Assumptions:
# - You are inside the goshbuild repo root.
# - demo-app/ contains the Go module to pack.
# - goshbuild.sh is available at the repo root, or on PATH as goshbuild.sh.
#
# Usage:
#   bash ./test_goshbuild.sh
#   GOSHBUILD=/path/to/goshbuild.sh bash ./test_goshbuild.sh
#
set -u

say() { echo "[manual] $*"; }
die() { echo "[manual] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need bash
need go
need tar
need base64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
DEMO_DIR="${REPO_ROOT}/demo-app"
OUT_DIR="${REPO_ROOT}/dist-demo-app"

[[ -d "${DEMO_DIR}" ]] || die "demo-app not found under repo root"
[[ -f "${DEMO_DIR}/go.mod" ]] || die "go.mod not found in demo-app"
mkdir -p "${OUT_DIR}"

# ------------------------------------------------------------
# Locate goshbuild.sh from the parent folder first.
# ------------------------------------------------------------
GOSHBUILD="${GOSHBUILD:-}"
if [[ -z "${GOSHBUILD}" ]]; then
  if [[ -x "${REPO_ROOT}/goshbuild.sh" ]]; then
    GOSHBUILD="${REPO_ROOT}/goshbuild.sh"
  elif command -v goshbuild.sh >/dev/null 2>&1; then
    GOSHBUILD="goshbuild.sh"
  else
    die "could not find goshbuild.sh. Put it in the repo root, or set GOSHBUILD=/path/to/goshbuild.sh"
  fi
fi

say "using goshbuild: ${GOSHBUILD}"
say "demo app root   : ${DEMO_DIR}"
say "output review dir: ${OUT_DIR}"

# ------------------------------------------------------------
# Extract module name -> MODULE_SAFE
# ------------------------------------------------------------
MOD_LINE="$(grep -E '^module[[:space:]]+' "${DEMO_DIR}/go.mod" | head -n1 || true)"
[[ -n "${MOD_LINE}" ]] || die "could not parse module line in demo-app/go.mod"
MODULE_NAME="${MOD_LINE#module }"
MODULE_SAFE="$(echo "${MODULE_NAME}" | sed 's/[\/.]/_/g')"

RUNNER="${OUT_DIR}/${MODULE_SAFE}.run.sh"
TESTER="${OUT_DIR}/${MODULE_SAFE}.run.sh.test.sh"

say "module         : ${MODULE_NAME}"
say "module_safe    : ${MODULE_SAFE}"
say "expected runner : ${RUNNER}"

# ------------------------------------------------------------
# Step 1: Generate runner
# ------------------------------------------------------------
say ""
say "STEP 1/7: Pack (generate runner + tester)"
say "Command: ${GOSHBUILD} pack ${DEMO_DIR} ${RUNNER}"
"${GOSHBUILD}" pack "${DEMO_DIR}" "${RUNNER}" || die "goshbuild failed"

[[ -f "${RUNNER}" ]] || die "runner not generated: ${RUNNER}"
chmod +x "${RUNNER}" || true
say "ok runner generated: ${RUNNER}"

if [[ -f "${TESTER}" ]]; then
  say "ok tester generated: ${TESTER}"
else
  say "info tester not found (ok). Manual script will still continue."
fi

# ------------------------------------------------------------
# Step 2: Quick smoke run
# ------------------------------------------------------------
say ""
say "STEP 2/7: Smoke run (no args)"
say "Command: ${RUNNER}"
OUT_SMOKE="$("${RUNNER}" 2>&1 || true)"
echo "${OUT_SMOKE}"
say "ok smoke run executed (inspect output above)"

# ------------------------------------------------------------
# Step 3: Cache behavior with stable MMM_HOME
# ------------------------------------------------------------
say ""
say "STEP 3/7: Cache behavior with stable MMM_HOME"
MMM_HOME_STABLE="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
export MMM_HOME="${MMM_HOME_STABLE}"

say "MMM_HOME set to: ${MMM_HOME}"
say "First run (should be cache miss/build)"
OUT1="$("${RUNNER}" --goshbuild-test sentinel_manual 2>&1 || true)"
echo "${OUT1}" | sed -n '1,80p'
echo "${OUT1}" | grep -qi "cache miss" && say "ok saw: cache miss" || say "warn did not see 'cache miss' (check output)"
echo "${OUT1}" | grep -qi "build complete" && say "ok saw: build complete" || say "warn did not see 'build complete' (check output)"
echo "${OUT1}" | grep -q "sentinel_manual" && say "ok arg forwarding ok (sentinel)" || say "warn could not confirm sentinel (your Go app may not echo it)"

say ""
say "Second run (should be cache hit/no build)"
OUT2="$("${RUNNER}" --goshbuild-test sentinel_manual 2>&1 || true)"
echo "${OUT2}" | sed -n '1,80p'
echo "${OUT2}" | grep -qi "cache hit" && say "ok saw: cache hit" || say "warn did not see 'cache hit' (check output)"
echo "${OUT2}" | grep -qi "build complete" && die "unexpected rebuild on cache hit" || say "ok no rebuild on cache hit"

# ------------------------------------------------------------
# Step 4: Fresh MMM_HOME should rebuild
# ------------------------------------------------------------
say ""
say "STEP 4/7: Fresh MMM_HOME should cause cache miss"
MMM_HOME_FRESH="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
export MMM_HOME="${MMM_HOME_FRESH}"
say "MMM_HOME set to fresh: ${MMM_HOME}"
OUT3="$("${RUNNER}" --goshbuild-test sentinel_fresh 2>&1 || true)"
echo "${OUT3}" | sed -n '1,80p'
echo "${OUT3}" | grep -qi "cache miss" && say "ok fresh home caused cache miss" || say "warn did not see 'cache miss' (check output)"

# ------------------------------------------------------------
# Step 5: Marker presence
# ------------------------------------------------------------
say ""
say "STEP 5/7: Verify payload marker exists in runner"
grep -q "^__PAYLOAD_B64__$" "${RUNNER}" && say "ok marker found" || die "marker __PAYLOAD_B64__ not found"

# ------------------------------------------------------------
# Step 6: Corruption detection
# ------------------------------------------------------------
say ""
say "STEP 6/7: Corruption detection (should be rejected)"
CORR_RUNNER="${OUT_DIR}/${MODULE_SAFE}.run.corrupt.sh"
cp -f "${RUNNER}" "${CORR_RUNNER}" || die "failed to copy runner"
chmod +x "${CORR_RUNNER}" || true

TMP_CORR="${OUT_DIR}/.${MODULE_SAFE}.tmp.corrupt.$$"
awk '
  BEGIN {found=0; corrupted=0}
  /^__PAYLOAD_B64__$/ {found=1; print; next}
  {
    if(found==1 && corrupted==0 && $0 ~ /[^[:space:]]/) {
      c=substr($0,1,1)
      rest=substr($0,2)
      if(c=="A") c="B"; else c="A"
      print c rest
      corrupted=1
      next
    }
    print
  }
' "${CORR_RUNNER}" > "${TMP_CORR}" || die "failed to corrupt runner"
mv -f "${TMP_CORR}" "${CORR_RUNNER}"
chmod +x "${CORR_RUNNER}" || true

export MMM_HOME="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
OUTC="$("${CORR_RUNNER}" --goshbuild-test sentinel_corrupt 2>&1 || true)"
echo "${OUTC}" | sed -n '1,120p'
echo "${OUTC}" | grep -qi "mismatch\|corrupt" && say "ok corruption rejected (mismatch/corrupt seen)" || die "expected corruption rejection, but it ran"

# ------------------------------------------------------------
# Step 7: Optional run the auto-generated acceptance test
# ------------------------------------------------------------
say ""
say "STEP 7/7: Optional: run auto acceptance test if present"
if [[ -f "${TESTER}" ]]; then
  chmod +x "${TESTER}" || true
  say "Command: bash ${TESTER}"
  bash "${TESTER}"
else
  say "info no tester file found; skipping"
fi

say ""
say "ok MANUAL TEST COMPLETE"
say "Artifacts to inspect:"
say "  runner      : ${RUNNER}"
say "  corrupt     : ${CORR_RUNNER}"
say "  MMM_HOME dirs were temp-created (see logs above)."
