#!/usr/bin/env python3
"""Run both builds over a corpus of real-world PDFs and compare what they did.

For every PDF the two CLIs are given the same arguments and their whole
`--report json` and exit code are compared; that covers the statistics, every
warning's wording and count, and every refusal. With --render the outputs are
also rasterized with poppler and diffed pixel by pixel.

  python3 bench/corpus.py --corpus rust-sumi/validation/corpus --mode grayscale
"""
import argparse
import concurrent.futures
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUST = ROOT / "rust-sumi" / "target" / "release" / "sumi"
SPINEL = ROOT / "sumi" / "build" / "bin" / "sumi"


def run(binary, src, dst, mode, timeout):
    command = [str(binary), str(src), "-o", str(dst), "--overwrite",
               "--mode", mode, "--report", "json"]
    try:
        done = subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    return done.returncode, done.stderr.decode("utf-8", "replace").strip()


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


def render_difference(a, b, pages, dpi):
    """Mean and maximum per-pixel difference (0-255), or None if not comparable."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, pdf in (("a", a), ("b", b)):
            done = subprocess.run(
                ["pdftoppm", "-r", str(dpi), "-gray", "-l", str(pages), str(pdf), f"{tmp}/{name}"],
                capture_output=True)
            if done.returncode != 0:
                return None
        root = pathlib.Path(tmp)
        total, count, worst = 0, 0, 0
        names = sorted(p.name for p in root.glob("a-*.pgm"))
        if not names:
            return None
        for name in names:
            pb = root / name.replace("a-", "b-", 1)
            if not pb.exists():
                return None
            da, db = read_pgm((root / name).read_bytes()), read_pgm(pb.read_bytes())
            if len(da) != len(db):
                return None
            for x, y in zip(da, db):
                d = abs(x - y)
                total += d
                worst = max(worst, d)
            count += len(da)
        return {"mean": total / count if count else 0.0, "max": worst}


def compare(src, mode, timeout, render, pages, dpi):
    entry = {"input": src.name, "bytes": src.stat().st_size}
    with tempfile.TemporaryDirectory() as tmp:
        rd = pathlib.Path(tmp) / "r.pdf"
        sd = pathlib.Path(tmp) / "s.pdf"
        rc, rj = run(RUST, src, rd, mode, timeout)
        sc, sj = run(SPINEL, src, sd, mode, timeout)
        entry["rust_exit"] = rc
        entry["spinel_exit"] = sc
        entry["report_match"] = (rc == sc and rj == sj)
        if not entry["report_match"]:
            entry["rust_report"] = rj[:2000]
            entry["spinel_report"] = sj[:2000]
        if render and rc == 0 and sc == 0 and rd.exists() and sd.exists():
            entry["render"] = render_difference(rd, sd, pages, dpi)
    return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", default=str(ROOT / "rust-sumi" / "validation" / "corpus"))
    parser.add_argument("--mode", default="grayscale")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--pages", type=int, default=2)
    parser.add_argument("--dpi", type=int, default=50)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    corpus = sorted(pathlib.Path(args.corpus).glob("*.pdf"))
    if args.limit:
        corpus = corpus[:args.limit]
    if not corpus:
        sys.exit(f"no PDFs in {args.corpus}")
    print(f"{len(corpus)} PDFs, mode {args.mode}", file=sys.stderr)

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(compare, p, args.mode, args.timeout,
                               args.render, args.pages, args.dpi) for p in corpus]
        for i, f in enumerate(concurrent.futures.as_completed(futures), 1):
            entry = f.result()
            results.append(entry)
            if not entry["report_match"]:
                print(f"DIFF {entry['input']}", file=sys.stderr)
                print(f"  rust   (exit {entry['rust_exit']}): {entry.get('rust_report','')[:300]}",
                      file=sys.stderr)
                print(f"  spinel (exit {entry['spinel_exit']}): {entry.get('spinel_report','')[:300]}",
                      file=sys.stderr)
            if i % 50 == 0:
                print(f"  {i}/{len(corpus)}", file=sys.stderr)

    matched = sum(1 for e in results if e["report_match"])
    print(f"\nreport identical: {matched}/{len(results)}", file=sys.stderr)
    by_exit = {}
    for e in results:
        by_exit[e["rust_exit"]] = by_exit.get(e["rust_exit"], 0) + 1
    print("rust exit codes:", dict(sorted(by_exit.items(), key=lambda kv: str(kv[0]))), file=sys.stderr)
    rendered = [e["render"] for e in results if e.get("render")]
    if rendered:
        identical = sum(1 for r in rendered if r["max"] == 0)
        worst = max(r["max"] for r in rendered)
        mean = sum(r["mean"] for r in rendered) / len(rendered)
        print(f"rendered: {len(rendered)} compared, {identical} pixel-identical, "
              f"mean difference {mean:.4f}/255, worst pixel {worst}", file=sys.stderr)

    out = ROOT / "bench" / f"corpus-{args.mode}.json"
    out.write_text(json.dumps({"mode": args.mode, "count": len(results),
                               "report_identical": matched, "results": results},
                              ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
