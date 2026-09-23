#!/usr/bin/env bash
set -euo pipefail

bundle_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cpu_model="${CPU_MODEL:-SpacemiT K1}"
threads="${PERF_THREADS:-}"
data_path="${OPENCV_TEST_DATA_PATH:-$bundle_dir/testdata}"
[[ -d "$data_path" ]] || { echo "Test data not found: $data_path" >&2; exit 1; }
export OPENCV_TEST_DATA_PATH="$data_path"
mkdir -p "$bundle_dir/results"

IFS=',' read -r -a modules < "$bundle_dir/modules.txt"
for module in "${modules[@]}"; do
  binary="$bundle_dir/bin/opencv_perf_$module"
  result="$bundle_dir/results/$module-$cpu_model.xml"
  args=("--gtest_output=xml:$result" --perf_force_samples=20 --perf_min_samples=20)
  if [[ -n "$threads" ]]; then
    [[ "$threads" =~ ^[1-9][0-9]*$ ]] || { echo "PERF_THREADS must be a positive integer" >&2; exit 1; }
    args+=("--perf_threads=$threads")
  fi
  if [[ "$module" == dnn ]]; then
    args+=("--gtest_filter=-DNNTestNetwork*")
  fi
  echo "Running $module; result: $result"
  "$binary" "${args[@]}"
done
