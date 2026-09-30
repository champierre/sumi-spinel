#!/bin/bash
# Compares the Rust sumi and the Spinel port on every fixture, in every mode:
# the JSON report (statistics, warnings and exit code) must be identical, and
# the rendered pages are diffed separately by bench/compare.py.
cd "$(dirname "$0")/.." || exit 1
RUST=rust-sumi/target/release/sumi
SPINEL=sumi/build/bin/sumi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
for f in rust-sumi/fixtures/*.pdf rust-sumi/samples/equal-pay.pdf rust-sumi/bench/inputs/*.pdf; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .pdf)
  for m in "--mode grayscale" "--mode monochrome" "--mode monochrome --dither" \
           "--gray-model colorimetric" "--mode monochrome --threshold 0.25" "--strict"; do
    r=$($RUST "$f" -o "$TMP/r.pdf" --overwrite --report json $m 2>&1 >/dev/null); rc=$?
    s=$($SPINEL "$f" -o "$TMP/s.pdf" --overwrite --report json $m 2>&1 >/dev/null); sc=$?
    if [ "$r" = "$s" ] && [ "$rc" = "$sc" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "DIFF $b [$m]"
      echo "  rust   (exit $rc): $r"
      echo "  spinel (exit $sc): $s"
    fi
  done
done
echo "$pass matched, $fail differed"
[ "$fail" = 0 ]
