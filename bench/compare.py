#!/usr/bin/env python3
"""Compare sumi's Rust build, the Spinel port and the same port under CRuby.

The port is plain Ruby with one engine-gated FFI module, so CRuby runs the very
same source; it is included as the third tool, which is what says how much of
the port's speed comes from Spinel rather than from the rewrite.

Same methodology as the upstream bench/bench.py: each tool is run as a command line
program, wall-clock time and peak RSS come from /usr/bin/time, and the outputs are
checked with poppler for leftover color and for extractable text. Standard library only.

Usage: compare.py [--runs 10] [--warmup 1] [--mode grayscale]
"""
import argparse
import difflib
import json
import pathlib
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
INPUTS = ROOT / "rust-sumi" / "bench" / "inputs"
OUTPUTS = HERE / "outputs"
RESULTS = HERE / "results.json"

RUST = ROOT / "rust-sumi" / "target" / "release" / "sumi"
SPINEL = ROOT / "sumi" / "build" / "bin" / "sumi"
CRUBY_ROOT = ROOT / "sumi"

# name -> the command that converts src to dst
TOOLS = {
    "rust": lambda src, dst, mode: [str(RUST), str(src), "-o", str(dst), "--overwrite",
                                    "--mode", mode],
    "spinel": lambda src, dst, mode: [str(SPINEL), str(src), "-o", str(dst), "--overwrite",
                                      "--mode", mode],
    "cruby": lambda src, dst, mode: ["ruby", "-I", str(CRUBY_ROOT), str(CRUBY_ROOT / "bin" / "sumi.rb"),
                                     str(src), "-o", str(dst), "--overwrite", "--mode", mode],
}


class ToolFailed(Exception):
    def __init__(self, name, code, stderr):
        super().__init__(f"{name} failed with exit code {code}")
        self.code, self.stderr = code, stderr


def timed_run(command):
    """Runs a command under /usr/bin/time; returns (seconds, peak RSS in bytes)."""
    start = time.perf_counter()
    result = subprocess.run(["/usr/bin/time", "-v", *command], capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    if result.returncode != 0:
        raise ToolFailed(command[0], result.returncode, result.stderr[-2000:])
    rss = int(re.search(r"Maximum resident set size \(kbytes\): (\d+)", result.stderr).group(1)) * 1024
    return elapsed, rss


def page_count(pdf):
    out = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True).stdout
    match = re.search(r"Pages:\s+(\d+)", out)
    return int(match.group(1)) if match else None


def colored_pixels(pdf, pages=3):
    """Pixels whose RGB channels differ by more than 3, on the first pages at 30 dpi."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["pdftoppm", "-r", "30", "-l", str(pages), str(pdf), f"{tmp}/p"],
                       check=True, capture_output=True)
        colored = 0
        for ppm in sorted(pathlib.Path(tmp).glob("p-*.ppm")):
            data = ppm.read_bytes()
            pos, fields = 0, []
            while len(fields) < 4:
                while data[pos:pos + 1].isspace():
                    pos += 1
                start = pos
                while not data[pos:pos + 1].isspace():
                    pos += 1
                fields.append(data[start:pos])
            pixels = data[pos + 1:]
            colored += sum(
                1 for i in range(0, len(pixels) - 2, 3)
                if max(pixels[i], pixels[i + 1], pixels[i + 2]) - min(pixels[i], pixels[i + 1], pixels[i + 2]) > 3
            )
        return colored


def text_similarity(original, converted):
    def text(pdf):
        out = subprocess.run(["pdftotext", str(pdf), "-"], capture_output=True, text=True,
                             errors="replace").stdout
        return re.sub(r"\s+", "", out)
    a, b = text(original), text(converted)
    if not a and not b:
        return 1.0
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


def render_difference(a, b, dpi=72):
    """Mean and maximum per-pixel difference (0-255) between two PDFs rendered as gray."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, pdf in (("a", a), ("b", b)):
            subprocess.run(["pdftoppm", "-r", str(dpi), "-gray", str(pdf), f"{tmp}/{name}"],
                           check=True, capture_output=True)
        root = pathlib.Path(tmp)
        total, count, worst = 0, 0, 0
        for pa in sorted(root.glob("a-*.pgm")):
            pb = root / pa.name.replace("a-", "b-", 1)
            if not pb.exists():
                return None
            da, db = read_pgm(pa.read_bytes()), read_pgm(pb.read_bytes())
            if len(da) != len(db):
                return None
            for x, y in zip(da, db):
                d = abs(x - y)
                total += d
                worst = max(worst, d)
            count += len(da)
        return {"mean": total / count if count else 0.0, "max": worst}


def read_pgm(data):
    pos, fields = 0, []
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    return data[pos + 1:]


def machine():
    cpu = re.search(r"model name\s*:\s*(.+)", pathlib.Path("/proc/cpuinfo").read_text()).group(1).strip()
    memory = int(re.search(r"MemTotal:\s+(\d+) kB", pathlib.Path("/proc/meminfo").read_text()).group(1)) * 1024
    release = platform.freedesktop_os_release()
    os_name = f"{release.get('NAME', 'Linux')} {release.get('VERSION_ID', '')}".strip()
    return {"cpu": cpu, "memory_gb": round(memory / 2**30),
            "os": f"{os_name} (Linux {platform.release()})"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--mode", default="grayscale")
    args = parser.parse_args()

    OUTPUTS.mkdir(exist_ok=True)
    inputs = sorted(INPUTS.glob("*.pdf"), key=lambda p: p.stat().st_size)
    if not inputs:
        sys.exit("no PDFs in rust-sumi/bench/inputs (run bench/fetch.py first)")

    report = {"machine": machine(), "mode": args.mode, "runs": args.runs,
              "binary_bytes": {"rust": RUST.stat().st_size, "spinel": SPINEL.stat().st_size},
              "results": []}
    print(json.dumps({k: v for k, v in report.items() if k != "results"}, ensure_ascii=False),
          file=sys.stderr)

    for src in inputs:
        entry = {"input": src.name, "pages": page_count(src),
                 "input_bytes": src.stat().st_size, "tools": {}}
        outputs = {}
        for name, build in TOOLS.items():
            dst = OUTPUTS / f"{src.stem}.{name}.pdf"
            outputs[name] = dst
            command = build(src, dst, args.mode)
            try:
                for _ in range(args.warmup):
                    timed_run(command)
                samples = [timed_run(command) for _ in range(args.runs)]
            except ToolFailed as failure:
                entry["tools"][name] = {"failed": True, "exit_code": failure.code}
                print(f"{src.name:28s} {name:8s} failed (exit {failure.code})", file=sys.stderr)
                continue
            times = [s[0] for s in samples]
            entry["tools"][name] = {
                "median_s": statistics.median(times),
                "min_s": min(times),
                "peak_rss_mb": statistics.median(s[1] for s in samples) / 2**20,
                "output_bytes": dst.stat().st_size,
                "colored_pixels": colored_pixels(dst),
                "text_similarity": text_similarity(src, dst),
            }
            t = entry["tools"][name]
            print(f"{src.name:28s} {name:8s} {t['median_s']*1000:8.1f} ms  "
                  f"{t['peak_rss_mb']:6.1f} MB  {t['output_bytes']/1e6:6.2f} MB  "
                  f"colored={t['colored_pixels']}  text={t['text_similarity']:.3f}",
                  file=sys.stderr)
        if all(not entry["tools"][n].get("failed") for n in TOOLS):
            entry["render_difference"] = render_difference(outputs["rust"], outputs["spinel"])
            rust = entry["tools"]["rust"]["median_s"]
            spinel = entry["tools"]["spinel"]["median_s"]
            cruby = entry["tools"]["cruby"]["median_s"]
            entry["slowdown"] = spinel / rust
            entry["cruby_slowdown"] = cruby / rust
            entry["spinel_speedup_over_cruby"] = cruby / spinel
            d = entry["render_difference"]
            print(f"{'':28s} {'ratio':8s} spinel {entry['slowdown']:5.2f}x of rust, "
                  f"cruby {entry['cruby_slowdown']:6.2f}x of rust, "
                  f"spinel {entry['spinel_speedup_over_cruby']:5.2f}x faster than cruby   "
                  f"render diff mean={d['mean']:.4f} max={d['max']}", file=sys.stderr)
        report["results"].append(entry)

    RESULTS.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {RESULTS}", file=sys.stderr)


if __name__ == "__main__":
    main()
