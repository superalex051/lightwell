#!/bin/bash
# Performance pass (PLAN 5.4). Read only on real data: scanbench only scans and reports.
#
#   scripts/perf.sh scan [path]   scanbench in release: nodes, wall seconds, peak phys_footprint (default ~)
#   scripts/perf.sh ui            the gated UI perf test (1M-item fixture: scan, then drill-in) with
#                                 Instruments' Hangs instrument attached to the app: every main-thread
#                                 hang the instrument reports, per phase; fixtures only
#
# Never scans / (the real-root test stays gated in the package tests).
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-scan}" in
  scan)
    target="${2:-$HOME}"
    if [ "$target" = "/" ]; then
      echo "perf: refusing to scan /" >&2
      exit 2
    fi
    swift build -c release --package-path Packages/Kit -j 3 --product scanbench >/dev/null
    bin="$(swift build -c release --package-path Packages/Kit --show-bin-path)/scanbench"
    "$bin" "$target" --json
    ;;
  ui)
    out="build/perf"
    rm -rf "$out" && mkdir -p "$out"
    app="$PWD/build/Build/Products/Debug/Lightwell.app/Contents/MacOS/Lightwell"
    # Job control: xcodebuild gets its own process group, so ending xctrace never signals it.
    set -m
    # TEST_RUNNER_ variables reach the UI test runner without the prefix.
    TEST_RUNNER_LIGHTWELL_UI_PERF=1 xcodebuild -project Lightwell.xcodeproj -scheme Lightwell \
      -derivedDataPath build -jobs 3 test -only-testing:LightwellUITests/PerfTests > "$out/xcodebuild.log" 2>&1 &
    xcodebuild_pid=$!
    # The app starts after the runner has built the fixture (about a minute).
    pid=""
    for _ in $(seq 1 900); do
      pid="$(pgrep -f "^$app" | head -1 || true)"
      [ -n "$pid" ] && break
      kill -0 "$xcodebuild_pid" 2>/dev/null || break
      sleep 1
    done
    if [ -z "$pid" ]; then
      wait "$xcodebuild_pid" || true
      tail -20 "$out/xcodebuild.log"
      echo "perf: the app never started" >&2
      exit 1
    fi
    # Records until the app quits (the test's teardown terminates it).
    xcrun xctrace record --instrument Hangs --attach "$pid" --time-limit 300s --output "$out/hangs.trace" \
      > "$out/xctrace.log" 2>&1 || true
    status=0
    wait "$xcodebuild_pid" || status=$?
    grep -E "^PERF |Test Case .*(passed|failed)|error:" "$out/xcodebuild.log" || true
    xcrun xctrace export --input "$out/hangs.trace" --toc > "$out/toc.xml"
    xcrun xctrace export --input "$out/hangs.trace" \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' > "$out/hangs.xml"
    python3 -I scripts/perf_hangs.py "$out/toc.xml" "$out/hangs.xml" "$out/xcodebuild.log"
    exit "$status"
    ;;
  *)
    echo "usage: scripts/perf.sh scan [path] | ui" >&2
    exit 2
    ;;
esac
