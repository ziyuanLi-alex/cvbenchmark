#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${OPENCV_VERSION:-5.x}"
opencv_extra_version="${OPENCV_EXTRA_VERSION:-5.x}"
modules="${PERF_MODULES:-core,imgproc}"
build_type="${BUILD_TYPE:-Release}"
jobs="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
toolchain_root="${SPACEMIT_TOOLCHAIN_ROOT:-}"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "This toolchain package requires a Linux x86_64 build host." >&2
  exit 1
fi
if [[ -z "$toolchain_root" ]]; then
  echo "Set SPACEMIT_TOOLCHAIN_ROOT to the extracted Linux/glibc toolchain directory." >&2
  exit 1
fi
toolchain_root="$(cd "$toolchain_root" && pwd)"
export SPACEMIT_TOOLCHAIN_ROOT="$toolchain_root"
for command_name in cmake ninja git tar readelf; do
  command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
done
[[ -d "$toolchain_root/sysroot" || -n "${SPACEMIT_SYSROOT:-}" ]] || {
  echo "No sysroot found in $toolchain_root; set SPACEMIT_SYSROOT if it is elsewhere." >&2
  exit 1
}

source_ref="$(git -C "$repo_dir/opencv" rev-parse "$version^{commit}" 2>/dev/null || true)"
source_head="$(git -C "$repo_dir/opencv" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$source_ref" || "$source_head" != "$source_ref" ]]; then
  echo "OpenCV submodule must be checked out at $version before building." >&2
  echo "Run: git -C opencv checkout $version" >&2
  exit 1
fi
extra_ref="$(git -C "$repo_dir/opencv_extra" rev-parse "$opencv_extra_version^{commit}" 2>/dev/null || true)"
extra_head="$(git -C "$repo_dir/opencv_extra" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$extra_ref" || "$extra_head" != "$extra_ref" ]]; then
  echo "opencv_extra submodule must be checked out at $opencv_extra_version before building." >&2
  echo "Run: git -C opencv_extra checkout $opencv_extra_version" >&2
  exit 1
fi
if [[ ! "$modules" =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]]; then
  echo "PERF_MODULES must be a comma-separated list of OpenCV module names." >&2
  exit 1
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer." >&2
  exit 1
fi
if [[ "$build_type" != Release && "$build_type" != Debug ]]; then
  echo "BUILD_TYPE must be Release or Debug." >&2
  exit 1
fi

safe_version="${version//\//_}"
build_dir="$repo_dir/build_k1_${safe_version}_${build_type,,}"
bundle_dir="$build_dir/bundle"
cmake_list="core,imgproc,imgcodecs,ts,$modules"
perf_list="${modules//,/;}"

cmake -S "$repo_dir/opencv" -B "$build_dir" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$repo_dir/cmake/toolchains/spacemit-k1-llvm.cmake" \
  -DSPACEMIT_TOOLCHAIN_ROOT="$toolchain_root" \
  -DSPACEMIT_SYSROOT="${SPACEMIT_SYSROOT:-$toolchain_root/sysroot}" \
  -DCMAKE_BUILD_TYPE="$build_type" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=ON \
  -DBUILD_opencv_python3=OFF \
  -DBUILD_JAVA=OFF \
  -DBUILD_LIST="$cmake_list" \
  -DOPENCV_BUILD_PERF_TEST_MODULES_LIST="$perf_list" \
  -DOPENCV_FORCE_3RDPARTY_BUILD=ON \
  -DCPU_BASELINE=RVV \
  -DCPU_BASELINE_REQUIRE=RVV \
  -DRISCV_RVV_SCALABLE=ON \
  -DWITH_OPENCL=OFF \
  -DWITH_LAPACK=OFF \
  -DWITH_EIGEN=OFF \
  -DWITH_GTK=OFF \
  -DWITH_QT=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_GSTREAMER=OFF

cmake --build "$build_dir" --target opencv_perf_tests --parallel "$jobs"
rm -rf -- "$bundle_dir"
mkdir -p "$bundle_dir/bin"
IFS=',' read -r -a module_array <<< "$modules"
for module in "${module_array[@]}"; do
  binary="$build_dir/bin/opencv_perf_$module"
  [[ -x "$binary" ]] || { echo "Missing performance binary: $binary" >&2; exit 1; }
  cp "$binary" "$bundle_dir/bin/"
done
cp "$repo_dir/scripts/run-perf-k1.sh" "$bundle_dir/run-perf.sh"
chmod +x "$bundle_dir/run-perf.sh"
printf '%s\n' "$version" > "$bundle_dir/opencv-version.txt"
printf '%s\n' "$modules" > "$bundle_dir/modules.txt"
git -C "$repo_dir/opencv" rev-parse HEAD > "$bundle_dir/opencv-commit.txt"
git -C "$repo_dir/opencv_extra" rev-parse HEAD > "$bundle_dir/opencv-extra-commit.txt"

for binary in "$bundle_dir"/bin/opencv_perf_*; do
  readelf -h "$binary" | grep -q 'Machine:.*RISC-V' || {
    echo "Unexpected binary architecture: $binary" >&2; exit 1;
  }
done
tar -C "$bundle_dir" -czf "$build_dir/cvbenchmark-k1-${safe_version}-${build_type,,}.tar.gz" .
echo "Bundle: $build_dir/cvbenchmark-k1-${safe_version}-${build_type,,}.tar.gz"
echo "Test data is separate: rsync opencv_extra/testdata/ to the target bundle's testdata/."
