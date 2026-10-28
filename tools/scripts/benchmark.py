#!/usr/bin/env python3
"""Measure warm launches on a running desktop. No installation or downloads."""

import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / "build/bin/mdf")
    parser.add_argument("--size-kib", type=int, default=100)
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.runs < 1 or args.size_kib < 1:
        parser.error("--runs and --size-kib must be positive")
    binary = args.binary.resolve()
    unit = (root / "tests/fixtures/core.md").read_bytes()
    data = unit * math.ceil(args.size_kib * 1024 / len(unit))
    env = os.environ.copy()
    env["FLTK_BACKEND"] = "wayland"
    samples = []
    (root / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="benchmark-", dir=root / "build") as directory:
        fixture = Path(directory) / "document.md"
        fixture.write_bytes(data)
        for index in range(args.runs + 2):
            start = time.perf_counter()
            try:
                run = subprocess.run(
                    [str(binary), "--benchmark", str(fixture)], env=env,
                    capture_output=True, text=True, timeout=30, check=True,
                )
            except subprocess.CalledProcessError as error:
                parser.exit(1, f"Benchmark failed: {error.stderr.strip()}\n")
            sample = json.loads(run.stdout)["metrics"]
            sample["process_lifecycle_ms"] = (time.perf_counter() - start) * 1000
            if index >= 2:
                samples.append(sample)
    times = sorted(sample.get("first_document_ms", sample["first_frame_ms"]) for sample in samples)
    report = {
        "binary": str(binary), "backend": "wayland", "bytes": len(data),
        "cache_condition": "warm files and desktop libraries", "warmups": 2,
        "milestone": "first stable document viewport after native flush; excludes compositor scanout",
        "count": args.runs, "median_ms": statistics.median(times),
        "p95_ms": times[math.ceil(0.95 * args.runs) - 1],
        "max_rss_kib": max(sample["rss_kib"] for sample in samples),
        "samples": samples,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "samples"}, indent=2))


if __name__ == "__main__":
    main()
