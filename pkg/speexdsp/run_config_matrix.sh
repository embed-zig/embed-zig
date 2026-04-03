#!/usr/bin/env bash

set -u -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
zig_bin="${ZIG_BIN:-zig}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/speexdsp-config-matrix.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

configs=(
  "default_path|"
  "config_default|pkg/speexdsp/config.default.h"
  "float_smallft_explicit|pkg/speexdsp/test_runner/config/float_smallft.explicit.h"
  "float_smallft_no_vla|pkg/speexdsp/test_runner/config/float_smallft.no_vla.h"
  "fixed_smallft_explicit|pkg/speexdsp/test_runner/config/fixed_smallft.explicit.h"
  "fixed_smallft_no_vla|pkg/speexdsp/test_runner/config/fixed_smallft.no_vla.h"
  "fixed_kiss_fft_explicit|pkg/speexdsp/test_runner/config/fixed_kiss_fft.explicit.h"
  "fixed_kiss_fft_no_vla|pkg/speexdsp/test_runner/config/fixed_kiss_fft.no_vla.h"
)

extract_metric() {
  local logfile="$1"
  local scenario="$2"
  local field="$3"

  awk -v target_scenario="$scenario" -v target_field="$field" '
    /SPEEXDSP_METRIC/ {
      scenario = ""
      value = ""
      for (i = 1; i <= NF; i += 1) {
        split($i, pair, "=")
        if (pair[1] == "scenario") scenario = pair[2]
        if (pair[1] == target_field) value = pair[2]
      }
      if (scenario == target_scenario) {
        print value
        exit 0
      }
    }
  ' "$logfile"
}

extract_failure() {
  local logfile="$1"

  awk '
    /SyntheticAecTooWeak|PlaybackCaptureAecTooWeak|DirtyResetAecTooWeak|FreshResetAecTooWeak|ResetResidualRatioDrift|Unexpected/ {
      failure = $0
    }
    END {
      if (failure != "") print failure
    }
  ' "$logfile"
}

print_metric() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    printf '%s%%' "$value"
  else
    printf '%s' "-"
  fi
}

printf '%-26s %-6s %-10s %-10s %-10s %-10s %s\n' \
  "config" "result" "synthetic" "split" "reset_f" "reset_d" "detail"

for entry in "${configs[@]}"; do
  IFS='|' read -r label header <<<"$entry"
  logfile="$tmp_dir/${label}.log"

  cmd=("$zig_bin" "build" "test-speexdsp" "-Dspeexdsp=true")
  if [[ -n "$header" ]]; then
    cmd+=("-Dspeexdsp_config_header=${header}")
  fi

  (
    cd "$repo_root" &&
      SPEEXDSP_MATRIX_REPORT=1 "${cmd[@]}"
  ) >"$logfile" 2>&1
  rc=$?

  if [[ $rc -eq 0 ]]; then
    result="PASS"
    detail="-"
  else
    result="FAIL"
    detail="$(extract_failure "$logfile")"
    if [[ -z "$detail" ]]; then
      detail="see log"
    fi
  fi

  synthetic="$(extract_metric "$logfile" "synthetic" "residual_percent")"
  split_metric="$(extract_metric "$logfile" "playback_capture" "residual_percent")"
  reset_fresh="$(extract_metric "$logfile" "reset_fresh" "residual_percent")"
  reset_dirty="$(extract_metric "$logfile" "reset_dirty" "residual_percent")"

  printf '%-26s %-6s %-10s %-10s %-10s %-10s %s\n' \
    "$label" \
    "$result" \
    "$(print_metric "$synthetic")" \
    "$(print_metric "$split_metric")" \
    "$(print_metric "$reset_fresh")" \
    "$(print_metric "$reset_dirty")" \
    "$detail"
done
