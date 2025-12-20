#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

input_0="${root_dir}/testdata/qoi/frame_0.qoi"
input_1="${root_dir}/testdata/qoi/frame_1.qoi"
input_2="${root_dir}/testdata/qoi/frame_2.qoi"
golden_0="${root_dir}/testdata/qoi_golden/frame_000000.qoi"
golden_1="${root_dir}/testdata/qoi_golden/frame_000001.qoi"
golden_2="${root_dir}/testdata/qoi_golden/frame_000002.qoi"

output_qov="${tmp_dir}/roundtrip.qov"
output_dir="${tmp_dir}/decoded"

zig build run -- encode "${output_qov}" "${input_0}" "${input_1}" "${input_2}"
zig build run -- decode "${output_qov}" "${output_dir}"

cmp -s "${golden_0}" "${output_dir}/frame_000000.qoi"
cmp -s "${golden_1}" "${output_dir}/frame_000001.qoi"
cmp -s "${golden_2}" "${output_dir}/frame_000002.qoi"

echo "Golden CLI roundtrip ok: ${output_dir}"
