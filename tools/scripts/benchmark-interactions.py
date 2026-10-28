#!/usr/bin/env python3
"""Compare ReleaseFast startup and reader interactions in alternating pairs."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time


def stats(values):
    values = sorted(values)
    return {"count": len(values), "median_ms": statistics.median(values),
            "p95_ms": values[math.ceil(len(values) * .95) - 1]}


def summarize(samples, startup_samples):
    result = {
        "startup": stats([sample["launch_to_document_ms"] for sample in samples]),
        "scroll_80": stats([value for sample in samples for value in sample["scroll_draw_ms"]]),
    }
    if startup_samples:
        result["startup_with_interactions"] = result["startup"]
        result["startup"] = stats([sample["launch_to_document_ms"] for sample in startup_samples])
    for name in ("repeated_scroll", "resize", "toc"):
        series = [sample["interaction_profile"][name] for sample in samples]
        values = [value for row in series for value in row["to_flush_ms"]]
        result[name] = stats(values) if values else {"count": 0}
        handler = [value for row in series for value in row["handler_ms"]]
        result[name]["handler"] = stats(handler) if handler else {"count": 0}
        result[name]["counters"] = {key: sum(row["counters"][key] for row in series)
                                    for key in series[0]["counters"]}
    return result


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--binary", type=Path, default=root / "build/bin/mdf")
    parser.add_argument("--document", action="append", type=Path)
    parser.add_argument("--runs", type=int, default=8)
    parser.add_argument("--startup-runs", type=int, default=0,
                        help="Use a separate paired --benchmark series for startup guards (0 uses scroll launches)")
    parser.add_argument("--output", type=Path, default=root / "build/interaction-benchmark.json")
    parser.add_argument("--enforce", action="store_true", help="Fail if the matched 5%% guards or resize/TOC improvements fail")
    args = parser.parse_args()
    if args.runs < 2:
        parser.error("--runs must be at least 2")
    if args.startup_runs and args.startup_runs < 2:
        parser.error("--startup-runs must be zero or at least 2")
    documents = args.document or [root / f"assets/samples/SAMPLE-{size}-TEXT.md" for size in ("SMALL", "MID", "HUGE")]
    binaries = {"baseline": args.baseline.resolve(), "candidate": args.binary.resolve()}
    environment = {**os.environ, "FLTK_BACKEND": "wayland"}
    rows = {str(doc.resolve()): {name: [] for name in binaries} for doc in documents}
    startup_rows = {str(doc.resolve()): {name: [] for name in binaries} for doc in documents}
    report = {
        "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                     for name, path in binaries.items()},
        "cache_condition": "Warm files and libraries, same compositor and settings; two warmups per binary and document",
        "timing": "Parent launch to native document flush for startup; programmatic handler to synchronous FLTK flush for interactions; excludes compositor scanout",
        "runs": args.runs, "warmups": 2, "documents": rows,
        "startup_runs": args.startup_runs,
        "startup_mode": "--benchmark" if args.startup_runs else "--profile-scroll",
        "cpu_affinity": sorted(os.sched_getaffinity(0)),
        "fltk_scaling_factor": environment.get("FLTK_SCALING_FACTOR", "default"),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def launch(name, document, mode):
        started = time.monotonic_ns()
        result = subprocess.run([str(binaries[name]), mode, str(document.resolve())],
                                env=environment, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(f"{name} {document.name}: {result.stderr.strip()}")
        data = json.loads(result.stdout)
        if data["mode"] != "ReleaseFast" or data["ui_mode"] != "Release" or data["renderer"] != "cairo":
            raise RuntimeError("Use two ReleaseFast builds of the production Cairo frontend")
        report["binaries"][name]["build"] = {
            **{key: data[key] for key in ("mode", "ui_mode", "renderer", "gui", "fltk_patch_id")},
            **{key: data["metrics"][key] for key in ("text_library_version", "drawing_library_version")},
        }
        builds = [row.get("build") for row in report["binaries"].values()]
        if all(builds) and builds[0] != builds[1]:
            raise RuntimeError("Use matched renderer libraries and FLTK patches")
        first_document = (data["main_started_ns"] - started) / 1e6 + data["metrics"]["first_document_ms"]
        return data, first_document

    for run in range(args.runs + 2):
        for index, document in enumerate(documents):
            names = list(binaries)
            if (run + index) % 2:
                names.reverse()
            for name in names:
                data, first_document = launch(name, document, "--profile-scroll")
                if data["scroll_frames"] != 80 or len(data["scroll_draw_ms"]) != 80:
                    raise RuntimeError("The original 80-position scroll series changed")
                sample = {key: data[key] for key in ("metrics", "scroll_draw_ms", "interaction_profile")}
                sample["launch_to_document_ms"] = first_document
                if run >= 2:
                    rows[str(document.resolve())][name].append(sample)
        print(f"Completed {'warmup' if run < 2 else 'pair'} {run + 1 if run < 2 else run - 1}", flush=True)
    if args.startup_runs:
        for run in range(args.startup_runs + 2):
            for index, document in enumerate(documents):
                names = list(binaries)
                if (run + index) % 2:
                    names.reverse()
                for name in names:
                    data, first_document = launch(name, document, "--benchmark")
                    if run >= 2:
                        startup_rows[str(document.resolve())][name].append({
                            "metrics": data["metrics"], "launch_to_document_ms": first_document})
            if run >= 2 and (run - 1) % 10 == 0:
                print(f"Completed startup pair {run - 1}", flush=True)
    passed = True
    for path, samples in rows.items():
        summary = {name: summarize(samples[name], startup_rows[path][name]) for name in binaries}
        if args.startup_runs:
            samples["startup_samples"] = startup_rows[path]
        guards = {}
        for phase, statistic in (("startup", "median_ms"), ("startup", "p95_ms"), ("scroll_80", "p95_ms")):
            guards[f"{phase}_{statistic}"] = summary["candidate"][phase][statistic] <= summary["baseline"][phase][statistic] * 1.05
        for phase in ("resize", "toc"):
            available = summary["candidate"][phase]["count"] and summary["baseline"][phase]["count"]
            guards[f"{phase}_improved"] = (summary["candidate"][phase]["median_ms"] < summary["baseline"][phase]["median_ms"]) if available else None
        samples["summary"] = summary
        samples["guards"] = guards
        passed = passed and all(value for value in guards.values() if value is not None)
        print(json.dumps({"document": Path(path).name, "summary": summary, "guards": guards}, indent=2))
    report["passed"] = passed
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    if args.enforce and not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
