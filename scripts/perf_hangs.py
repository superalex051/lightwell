"""Summarises the Hangs instrument for scripts/perf.sh ui.

Usage: perf_hangs.py <toc.xml> <potential-hangs.xml> <xcodebuild.log>

Reads every main-thread hang Instruments recorded in Lightwell (start, duration, type) and the
`PERF phase ...` times the UI perf test printed, then reports:
- the quiet scan window: hang count per type, the longest, and how many exceed 250 ms
  (PLAN 5.4: no main-thread hang over 250 ms during a scan);
- each drill-in: the longest hang starting within 1.5 s after the Return (PLAN 5.4: under 100 ms
  to the first frame; the instrument reports nothing shorter than about 100 ms).
Exit status 0 always; the verdicts are printed.
"""

import datetime
import re
import sys
import xml.etree.ElementTree as ElementTree


def trace_start(toc_path):
    text = open(toc_path, encoding="utf-8").read()
    match = re.search(r"<start-date>([^<]+)</start-date>", text)
    if not match:
        sys.exit("perf: no start date in the trace table of contents")
    return datetime.datetime.fromisoformat(match.group(1)).timestamp()


def hangs(table_path, start):
    """[(start seconds since epoch, duration seconds, type)] for the Lightwell process."""
    root = ElementTree.parse(table_path).getroot()
    by_id = {}
    for element in root.iter():
        if "id" in element.attrib:
            by_id[element.attrib["id"]] = element

    def value(element):
        if element is None:
            return None
        if "ref" in element.attrib:
            element = by_id[element.attrib["ref"]]
        return element

    result = []
    for row in root.iter("row"):
        begin = value(row.find("start-time"))
        length = value(row.find("duration"))
        kind = value(row.find("hang-type"))
        process = value(row.find("process"))
        if begin is None or length is None:
            continue
        if process is not None and "Lightwell" not in process.attrib.get("fmt", ""):
            continue
        result.append((start + int(begin.text) / 1e9, int(length.text) / 1e9, kind.text if kind is not None else "?"))
    return sorted(result)


def phases(log_path):
    found = {}
    for line in open(log_path, encoding="utf-8", errors="replace"):
        match = re.match(r"^PERF phase (.+) ([0-9]+\.[0-9]+)$", line.strip())
        if match:
            found[match.group(1)] = float(match.group(2))
    return found


def milliseconds(seconds):
    return f"{seconds * 1000:.0f} ms"


def main():
    start = trace_start(sys.argv[1])
    recorded = hangs(sys.argv[2], start)
    marks = phases(sys.argv[3])
    print(f"HANGS recorded in Lightwell: {len(recorded)} (all phases, including test-driven ones)")

    if "scan start" in marks and "scan end" in marks:
        window = [h for h in recorded if marks["scan start"] <= h[0] <= marks["scan end"]]
        types = {}
        for _, _, kind in window:
            types[kind] = types.get(kind, 0) + 1
        longest = max((h[1] for h in window), default=0)
        over = sum(1 for h in window if h[1] > 0.25)
        seconds = marks["scan end"] - marks["scan start"]
        detail = ", ".join(f"{count} {kind}" for kind, count in sorted(types.items())) or "none"
        print(f"HANGS scan window ({seconds:.0f} s, no test queries): {len(window)} ({detail}); "
              f"longest {milliseconds(longest)}; over 250 ms: {over}")
        print("HANGS scan verdict: " + ("PASS, no main-thread hang over 250 ms" if over == 0 else "FAIL, main-thread hangs over 250 ms"))
    else:
        print("HANGS scan window: phase marks missing")

    for name in sorted(k for k in marks if k.startswith("drill ")):
        press = marks[name]
        near = [h for h in recorded if press - 0.25 <= h[0] <= press + 1.5]
        if near:
            longest = max(h[1] for h in near)
            print(f"HANGS {name}: main thread blocked {milliseconds(longest)} after the Return "
                  f"({', '.join(h[2] for h in near)}); target under 100 ms: {'PASS' if longest < 0.1 else 'FAIL'}")
        else:
            print(f"HANGS {name}: no hang of 100 ms or more after the Return; target under 100 ms: PASS (main thread)")


if __name__ == "__main__":
    main()
