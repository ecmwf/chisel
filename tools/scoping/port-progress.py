#!/usr/bin/env python3
"""Port progress, derived read-only from port/TRACE.yaml (TRACE stays the source of truth).

`proven` is the only real-progress measure: a proven entry is translated AND proof-passed AND
independently reviewed. `in-progress` is work that exists but is not yet trustworthy, shown
as its own band so it never reads as done. Weighted by SLOC and by file count over the live
subset (every entry whose status is not `excluded`). This is a VIEW, never a source of
truth: it computes nothing that is not already in TRACE plus the SOURCE line counts.
"""
import argparse
import os
import sys

ORDER = ("proven", "in-progress", "unmapped")
GLYPH = {"proven": "#", "in-progress": "~", "unmapped": "."}
CLASSES = ("pure", "wide", "seam")


def load_trace(path):
    try:
        import yaml
    except ModuleNotFoundError:
        sys.stderr.write("port-progress: PyYAML not installed (pip install pyyaml); skipping the bar.\n")
        sys.exit(0)
    try:
        with open(path, encoding="utf-8") as handle:
            return yaml.safe_load(handle) or {}
    except FileNotFoundError:
        sys.stderr.write("port-progress: %s not found.\n" % path)
        sys.exit(0)


def count_lines(path):
    try:
        with open(path, "rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return None


def stacked_bar(weight, total, width=40):
    if total <= 0:
        return GLYPH["unmapped"] * width
    chars, used = [], 0
    for index, band in enumerate(ORDER):
        size = (width - used) if index == len(ORDER) - 1 else round(width * weight[band] / total)
        size = max(0, min(size, width - used))
        chars.append(GLYPH[band] * size)
        used += size
    return "".join(chars).ljust(width, GLYPH["unmapped"])[:width]


def percent(part, total):
    return 0.0 if total <= 0 else 100.0 * part / total


def files_word(count):
    return "file" if count == 1 else "files"


def main():
    default_trace = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "port", "TRACE.yaml",
    )
    ap = argparse.ArgumentParser(description="Read-only port progress from port/TRACE.yaml (proven = the only validated measure).")
    ap.add_argument("--trace", default=None, help="path to port/TRACE.yaml (default: the repo's port/TRACE.yaml)")
    ap.add_argument("trace_pos", nargs="?", default=None, help=argparse.SUPPRESS)
    args = ap.parse_args()
    trace_path = args.trace or args.trace_pos or default_trace
    base = os.path.dirname(os.path.dirname(os.path.abspath(trace_path)))
    data = load_trace(trace_path)
    source_root = (data.get("meta") or {}).get("source_root") or "source/"
    entries = data.get("files") or []

    files = {band: 0 for band in ORDER}
    sloc = {band: 0 for band in ORDER}
    excluded_files = excluded_sloc = missing = 0
    remaining_class = {name: 0 for name in CLASSES}

    for entry in entries:
        status = str(entry.get("status") or "unmapped").strip()
        lines = count_lines(os.path.join(base, source_root, str(entry.get("source") or "")))
        if lines is None:
            missing += 1
            lines = 0
        if status == "excluded":
            excluded_files += 1
            excluded_sloc += lines
            continue
        band = status if status in files else "unmapped"
        files[band] += 1
        sloc[band] += lines
        if band != "proven":
            for symbol in entry.get("symbols") or []:
                name = str(symbol.get("class") or "").strip()
                if name in remaining_class and str(symbol.get("status") or "") != "proven":
                    remaining_class[name] += 1

    live_files = sum(files.values())
    live_sloc = sum(sloc.values())

    print("Port progress  (read-only from port/TRACE.yaml; `proven` = the only validated measure)")
    if live_files == 0:
        print("  No live files in TRACE yet. Run Phase 0 scoping to populate the live subset.")
        return
    print("  Live subset: %d %s / %s SLOC   (excluded: %d %s / %s SLOC)" % (
        live_files, files_word(live_files), format(live_sloc, ","),
        excluded_files, files_word(excluded_files), format(excluded_sloc, ",")))
    print()
    if live_sloc > 0:
        print("  by SLOC   [%s]  proven %.0f%%  in-prog %.0f%%  unmapped %.0f%%" % (
            stacked_bar(sloc, live_sloc), percent(sloc["proven"], live_sloc),
            percent(sloc["in-progress"], live_sloc), percent(sloc["unmapped"], live_sloc)))
    print("  by files  [%s]  proven %.0f%%  in-prog %.0f%%  unmapped %.0f%%" % (
        stacked_bar(files, live_files), percent(files["proven"], live_files),
        percent(files["in-progress"], live_files), percent(files["unmapped"], live_files)))
    print()
    print("  Real (proven) progress: %.1f%% of live SLOC, %.1f%% of live files." % (
        percent(sloc["proven"], live_sloc), percent(files["proven"], live_files)))
    if sum(remaining_class.values()) > 0:
        print("  Ungated remainder by routine class: pure %d / wide %d / seam %d  (wide + seam cost most)." % (
            remaining_class["pure"], remaining_class["wide"], remaining_class["seam"]))
    if missing > 0:
        print("  Note: SLOC unavailable for %d file(s) (SOURCE not found); bars use what is countable." % missing)
    print("  Legend: # proven   ~ in-progress   . unmapped   (volume converted, not effort or time remaining)")


if __name__ == "__main__":
    main()
