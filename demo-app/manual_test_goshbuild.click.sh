#!/usr/bin/env bash
# manual_test_goshbuild.sh
# Manual, human-readable test runner for goshbuild.
#
# Assumptions:
# - You are inside a Go module folder (go.mod exists).
# - goshbuild.sh is either:
#     A) in the same folder, or
#     B) in the parent folder, or
#     C) on PATH as goshbuild.sh
#
# Usage:
#   bash ./manual_test_goshbuild.sh
#   # optional:
#   GOSHBUILD=/path/to/goshbuild.sh bash ./manual_test_goshbuild.sh
#
set -u

say() { echo "🧪 [manual] $*"; }
die() { echo "❌ [manual] $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need bash
need go
need tar
need base64

[[ -f "./go.mod" ]] || die "go.mod not found in current folder. cd into a Go module folder."

# ------------------------------------------------------------
# Locate goshbuild.sh
# ------------------------------------------------------------
GOSHBUILD="${GOSHBUILD:-}"
if [[ -z "$GOSHBUILD" ]]; then
  if [[ -x "./goshbuild.sh" ]]; then
    GOSHBUILD="./goshbuild.sh"
  elif [[ -x "../goshbuild.sh" ]]; then
    GOSHBUILD="../goshbuild.sh"
  elif command -v goshbuild.sh >/dev/null 2>&1; then
    GOSHBUILD="goshbuild.sh"
  else
    die "could not find goshbuild.sh. Put it here, or set GOSHBUILD=/path/to/goshbuild.sh"
  fi
fi

say "using goshbuild: $GOSHBUILD"

# ------------------------------------------------------------
# Extract module name → MODULE_SAFE (A-style)
# ------------------------------------------------------------
MOD_LINE="$(grep -E '^module[[:space:]]+' ./go.mod | head -n1 || true)"
[[ -n "$MOD_LINE" ]] || die "could not parse module line in go.mod"
MODULE_NAME="${MOD_LINE#module }"
MODULE_SAFE="$(echo "$MODULE_NAME" | sed 's/[\/.]/_/g')"

RUNNER="./${MODULE_SAFE}.run.sh"
TESTER="./${MODULE_SAFE}.run.sh.test.sh"

say "module      : $MODULE_NAME"
say "module_safe : $MODULE_SAFE"
say "expected runner: $RUNNER"

# ------------------------------------------------------------
# Step 1: Generate runner
# ------------------------------------------------------------
say ""
say "STEP 1/7: Pack (generate runner + tester)"
say "Command: $GOSHBUILD"
"$GOSHBUILD" || die "goshbuild failed"

[[ -f "$RUNNER" ]] || die "runner not generated: $RUNNER"
chmod +x "$RUNNER" || true
say "✅ runner generated: $RUNNER"

if [[ -f "$TESTER" ]]; then
  say "✅ tester generated: $TESTER"
else
  say "ℹ️ tester not found (ok). Manual script will still continue."
fi

# ------------------------------------------------------------
# Step 2: Quick smoke run
# ------------------------------------------------------------
say ""
say "STEP 2/7: Smoke run (no args)"
say "Command: $RUNNER"
OUT_SMOKE="$("$RUNNER" 2>&1 || true)"
echo "$OUT_SMOKE"
say "✅ smoke run executed (inspect output above)"

# ------------------------------------------------------------
# Step 3: Cache behavior (hit/miss) with stable MMM_HOME
# ------------------------------------------------------------
say ""
say "STEP 3/7: Cache behavior with stable MMM_HOME"
MMM_HOME_STABLE="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
export MMM_HOME="$MMM_HOME_STABLE"

say "MMM_HOME set to: $MMM_HOME"
say "First run (should be cache miss/build)"
OUT1="$("$RUNNER" --goshbuild-test sentinel_manual 2>&1 || true)"
echo "$OUT1" | sed -n '1,80p'
echo "$OUT1" | grep -qi "cache miss" && say "✅ saw: cache miss" || say "⚠️ did not see 'cache miss' (check output)"
echo "$OUT1" | grep -qi "build complete" && say "✅ saw: build complete" || say "⚠️ did not see 'build complete' (check output)"
echo "$OUT1" | grep -q "sentinel_manual" && say "✅ arg forwarding ok (sentinel)" || say "⚠️ could not confirm sentinel (your Go app may not echo it)"

say ""
say "Second run (should be cache hit/no build)"
OUT2="$("$RUNNER" --goshbuild-test sentinel_manual 2>&1 || true)"
echo "$OUT2" | sed -n '1,80p'
echo "$OUT2" | grep -qi "cache hit" && say "✅ saw: cache hit" || say "⚠️ did not see 'cache hit' (check output)"
echo "$OUT2" | grep -qi "build complete" && die "unexpected rebuild on cache hit" || say "✅ no rebuild on cache hit"

# ------------------------------------------------------------
# Step 4: Fresh MMM_HOME should rebuild
# ------------------------------------------------------------
say ""
say "STEP 4/7: Fresh MMM_HOME should cause cache miss"
MMM_HOME_FRESH="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
export MMM_HOME="$MMM_HOME_FRESH"
say "MMM_HOME set to fresh: $MMM_HOME"
OUT3="$("$RUNNER" --goshbuild-test sentinel_fresh 2>&1 || true)"
echo "$OUT3" | sed -n '1,80p'
echo "$OUT3" | grep -qi "cache miss" && say "✅ fresh home caused cache miss" || say "⚠️ did not see 'cache miss' (check output)"

# ------------------------------------------------------------
# Step 5: Marker presence
# ------------------------------------------------------------
say ""
say "STEP 5/7: Verify payload marker exists in runner"
grep -q "^__PAYLOAD_B64__$" "$RUNNER" && say "✅ marker found" || die "marker __PAYLOAD_B64__ not found"

# ------------------------------------------------------------
# Step 6: Corruption detection (robust)
# Strategy: copy runner -> flip first char of first non-empty payload line after marker
# ------------------------------------------------------------
say ""
say "STEP 6/7: Corruption detection (should be rejected)"
CORR_RUNNER="./${MODULE_SAFE}.run.corrupt.sh"
cp -f "$RUNNER" "$CORR_RUNNER" || die "failed to copy runner"
chmod +x "$CORR_RUNNER" || true

# rewrite the corrupt runner deterministically
TMP_CORR="./.${MODULE_SAFE}.tmp.corrupt.$$"
awk '
  BEGIN {found=0; corrupted=0}
  /^__PAYLOAD_B64__$/ {found=1; print; next}
  {
    if(found==1 && corrupted==0 && $0 ~ /[^[:space:]]/) {
      # flip first character of the base64 line
      c=substr($0,1,1)
      rest=substr($0,2)
      if(c=="A") c="B"; else c="A"
      print c rest
      corrupted=1
      next
    }
    print
  }
' "$CORR_RUNNER" > "$TMP_CORR" || die "failed to corrupt runner"
mv -f "$TMP_CORR" "$CORR_RUNNER"
chmod +x "$CORR_RUNNER" || true

export MMM_HOME="$(mktemp -d 2>/dev/null || mktemp -d -t mmm)"
OUTC="$("$CORR_RUNNER" --goshbuild-test sentinel_corrupt 2>&1 || true)"
echo "$OUTC" | sed -n '1,120p'
echo "$OUTC" | grep -qi "mismatch\|corrupt" && say "✅ corruption rejected (mismatch/corrupt seen)" || die "expected corruption rejection, but it ran"

# ------------------------------------------------------------
# Step 7: Optional run the auto-generated acceptance test (if present)
# ------------------------------------------------------------
say ""
say "STEP 7/7: Optional: run auto acceptance test if present"
if [[ -f "$TESTER" ]]; then
  chmod +x "$TESTER" || true
  say "Command: bash $TESTER"
  bash "$TESTER"
else
  say "ℹ️ no tester file found; skipping"
fi

say ""
say "✅ MANUAL TEST COMPLETE"
say "Artifacts to inspect:"
say "  runner      : $RUNNER"
say "  corrupt     : $CORR_RUNNER"
say "  MMM_HOME dirs were temp-created (see logs above)."