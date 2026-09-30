# sumi, rewritten in Spinel

[champierre/sumi](https://github.com/champierre/sumi) converts the colours of a
PDF to grayscale or black-and-white without rasterizing it: it rewrites the
colour operators, images, shadings and annotation colours and leaves the text,
fonts and vector geometry alone. It is written in Rust.

This is a rewrite of it in the Ruby subset that [Spinel](https://github.com/matz/spinel),
Matz's ahead-of-time Ruby compiler, turns into a native binary — together with
the measurements comparing the two.

English | [日本語](README.md)

```
sumi-spinel/
  sumi/            the port: a spin package with the library, the CLI and its tests
  rust-sumi/       a clone of champierre/sumi, built with cargo, as the reference
                   (cloned, not vendored: it is not part of this repository)
  bench/
    compare.py     the benchmark: rust vs spinel vs the same port under CRuby
    parity.sh      the conformance check: identical --report json on every fixture
    corpus.py      the same comparison over 405 real-world PDFs
    results-*.json, corpus-*.json
```

## Building and running

```sh
# the reference: clone it and build it
git clone https://github.com/champierre/sumi.git rust-sumi
cd rust-sumi && cargo build --release && cd ..

# the port (needs spinel and spin on PATH, and zlib's headers)
cd sumi && spin build && cd ..

sumi/build/bin/sumi input.pdf -o output.pdf --mode grayscale
```

The two CLIs take the same arguments, print the same messages, return the same
exit codes and emit the same `--report json`.

## What the port covers

Everything the Rust version does, and by the same route. The Rust crate leans on
three libraries — `lopdf` for the PDF object model, `flate2` for DEFLATE and
`zune-jpeg` for `/DCTDecode` images — and only the first and third had to be
written out:

- **the PDF reader** — cross-reference tables and cross-reference streams,
  hybrid files, object streams, incremental updates, and a declaration scan that
  recovers objects a broken cross-reference table misses;
- **the PDF writer** — object streams and a cross-reference stream, the same
  PDF 1.5 output shape the Rust build writes;
- **the filters** — Flate with the PNG and TIFF predictors, LZW, ASCIIHex,
  ASCII85 and RunLength;
- **a JPEG decoder** — baseline and progressive (SOF0/SOF1/SOF2), any
  subsampling, restart intervals and the Adobe APP14 marker;
- **the conversion itself** — colour spaces (ICCBased, Indexed, Separation,
  DeviceN, Lab, Pattern), PDF functions (sampled, exponential, stitching and the
  PostScript calculator), the content stream rewriter, image and inline-image
  conversion, shading resampling, transparency groups, Type 3 glyphs,
  annotations and AcroForm fields.

DEFLATE is the one thing the port does not reimplement: `sumi/zlibffi.rb` binds
the system libz through Spinel's FFI, because the Rust build links a DEFLATE
library too and the comparison should be between the two programs rather than
between two DEFLATE implementations. (Spinel ships a `zlib` package with its own
DEFLATE; it is correct but compresses about 5% worse on already-packed data and
37% worse on the map's content stream, which would have made every output-size
comparison meaningless.)

The port is otherwise plain Ruby: the FFI module is behind
`if RUBY_ENGINE == "spinel"`, which Spinel drops before analysis, so CRuby runs
the identical source. That is what `spin test` uses — CRuby is the oracle, and
each snapshot is an agreement between the compiled binary and the interpreter.
It is also the third column of the benchmark below.

## Is the output the same?

Two checks, both in `bench/`.

**`bench/parity.sh`** runs both binaries over 12 documents (the repository's
fixtures, its sample, and the six benchmark inputs) in 6 option sets each
— grayscale, monochrome, monochrome with dithering, the colorimetric gray model,
a non-default threshold, and `--strict` — and compares the whole `--report json`
and the exit code.

**72 of 72 matched**: the same page, content-stream, colour-operator, image and
shading counts, the same warnings with the same wording and counts, the same
exit codes.

**`bench/compare.py`** renders both outputs with poppler at 72 dpi and diffs
them pixel by pixel. Every difference across the six benchmark documents has one
of two causes, and both are understood:

1. **The JPEG decoder rounds differently from `zune-jpeg`.** On the invoice's
   300×120 logo, 21% of the decoded gray samples differ — every one of them by
   exactly 1 of 255. Checked against libjpeg (through ImageMagick), the port's
   decoder is within 0.23% mean absolute error on every `/DCTDecode` image in the
   benchmark set. In monochrome mode a ±1 difference next to the threshold flips
   a pixel from black to white, which is why the "max" column there reads 255
   while the mean stays near 0.04/255.

2. **The port keeps a number's own spelling; the Rust build rounds it through
   `f32`.** `lopdf` parses a real into an `f32` and prints that back, so Chrome's
   `/FontMatrix [.00100000005 …]` is rewritten as `0.001` and a `/MediaBox` of
   `841.91998` as `841.92`. The port copies the token it read. Both are the same
   `f32`; poppler reads them as doubles, so glyph edges land a fraction of a
   pixel apart. On documents with neither cause — the infographic and the map —
   the two outputs render **identically, pixel for pixel**.

Apart from those, only one object in one document differs semantically across
the whole corpus, and it is the decoded JPEG of cause 1.

### 405 real-world PDFs

`bench/corpus.py` runs both builds over the corpus the sumi repository's own
validation harness collects — 400 public-domain PDFs pulled from Wikimedia
Commons across 20 subject axes (invoices, reports, presentations, maps, theses,
newspapers, …) plus the repository's fixtures, 1.4 GB in all — and compares the
whole `--report json` and the exit code, then renders both outputs and diffs
them.

```
405 PDFs, mode grayscale
report identical: 404/405
rust exit codes: {0: 400, 3: 1, 4: 4}
rendered: 400 compared, 200 pixel-identical, mean difference 0.0380/255, worst pixel 221

405 PDFs, mode monochrome
report identical: 404/405
```

Half the documents convert to a bit-for-bit identical rendering; the median
document's mean difference is exactly 0, and only two of 400 have any pixel
differing by more than 50 — both for the two reasons above.

The single report that differs — the same document in both modes — is a damaged
76-page PDF (poppler reports syntax errors reading it) where `lopdf` cannot parse
one object a page uses and refuses the file; the port reads that object and
converts. Its output has **no coloured pixel left on any of the 76 pages**.

The port's page count also agrees with poppler's on 404 of the 405 documents;
the exception is that same damaged file, where the page tree reaches 69 leaves
and poppler's own recovery finds 76.

### Deliberate differences

- **Damaged files.** Where `lopdf` gives up on a cross-reference table it cannot
  parse (`invalid PDF: failed parsing cross reference table`, exit 3), the port
  falls back to scanning the file for `N G obj` declarations and converts what it
  finds — which is what poppler and most viewers do with the same file. On 2200
  fuzzed PDFs the port converted 122 that the Rust build refused. Because sumi's
  contract is never to lose content silently, the repair is reported as a
  warning, so `--strict` still refuses such a file:

  ```
  sumi: warning: the cross-reference table could not be read; the file was
  rebuilt from the objects found in it
  ```

  A truncated stream inside an otherwise readable object is still lost content:
  converting a chrome invoice truncated to half its length recovered every page,
  content stream and colour operator, but 0.2-0.4% of the rendered pixels differ
  from the intact conversion.
- **12-bit JPEG** is reported as unsupported rather than decoded. YCCK (Adobe
  CMYK) JPEG is declined by both, for the reason the Rust source gives.
- On a corrupt JPEG the two decoders word their refusal differently
  (`bad Huffman value in JPEG` against zune-jpeg's `Bad Huffman Table`). Both
  leave the image in colour and warn.

### Robustness

2200 mutated PDFs — truncations, random byte flips, zeroed runs, spliced chunks
and injected garbage, over all 12 fixtures — produced **no crash, no unhandled
exception and no timeout** from the port. (Two real bugs came out of a smaller
first round and are fixed: a corrupt Huffman table could hand the DC decoder a
shift width past 64, and a damaged `/W` in a cross-reference stream could ask
for a field wider than an integer.)

## Benchmark

`bench/compare.py`, which follows the methodology of the upstream
`bench/bench.py`: each tool is run as a command line program the way an
application would call it, wall-clock time and peak RSS come from
`/usr/bin/time`, and afterwards the outputs are checked with poppler for
leftover colour and for extractable text. Median of 10 runs after 2 warmups.
`colored=0` and `text=1.000` held for every tool on every input.

### Grayscale (`--mode grayscale`)

AMD Ryzen 7 6800H, Omarchy 4.0.1 (Linux 7.1.9), gcc 16.2.1, rustc 1.98.0,
CRuby 3.4.10, spinel a6c990a. Median of 10 runs.

| input | pages | rust | spinel | CRuby | spinel / rust | spinel vs CRuby |
|---|---:|---:|---:|---:|---:|---:|
| invoice.pdf (0.34 MB) | 2 | 26 ms | 53 ms | 391 ms | 2.07x | 7.4x faster |
| equal-pay-infographic.pdf (0.30 MB) | 1 | 37 ms | 63 ms | 304 ms | 1.71x | 4.9x faster |
| nasa-sls-fact-sheet.pdf (0.30 MB) | 2 | 58 ms | 376 ms | 2463 ms | 6.46x | 6.6x faster |
| invoice-50pages.pdf (1.0 MB) | 50 | 85 ms | 146 ms | 902 ms | 1.73x | 6.2x faster |
| communia-poster.pdf (5.9 MB) | 1 | 593 ms | 1046 ms | 4311 ms | 1.76x | 4.1x faster |
| europe-map.pdf (6.7 MB) | 1 | 1575 ms | 2427 ms | 9609 ms | 1.54x | 4.0x faster |
| **geometric mean** | | | | | **2.18x** | **5.4x faster** |

CRuby, running the same source, is 11.7x the Rust build.

### Monochrome (`--mode monochrome`)

| input | rust | spinel | CRuby | spinel / rust |
|---|---:|---:|---:|---:|
| invoice.pdf | 25 ms | 53 ms | 398 ms | 2.13x |
| equal-pay-infographic.pdf | 36 ms | 62 ms | 306 ms | 1.72x |
| nasa-sls-fact-sheet.pdf | 21 ms | 364 ms | 2664 ms | 17.25x |
| invoice-50pages.pdf | 84 ms | 145 ms | 915 ms | 1.74x |
| communia-poster.pdf | 653 ms | 1252 ms | 5686 ms | 1.92x |
| europe-map.pdf | 1575 ms | 2428 ms | 9552 ms | 1.54x |
| **geometric mean** | | | | **2.62x** |

### Peak memory (grayscale)

| input | rust | spinel | CRuby |
|---|---:|---:|---:|
| invoice.pdf | 14.7 MB | 21.4 MB | 29.1 MB |
| equal-pay-infographic.pdf | 6.8 MB | 13.8 MB | 19.6 MB |
| nasa-sls-fact-sheet.pdf | 8.1 MB | 33.5 MB | 39.0 MB |
| invoice-50pages.pdf | 30.5 MB | 54.7 MB | 46.9 MB |
| communia-poster.pdf | 31.7 MB | 65.0 MB | 55.1 MB |
| europe-map.pdf | 72.8 MB | 113.2 MB | 105.5 MB |

Output size lands within 3% of the Rust build's on every input (-3.0% to +0.3%,
smaller on four of the six), since both write the same PDF 1.5 shape through the
same DEFLATE. The remaining spread is object-stream packing: the port batches
200 objects per stream where `lopdf` chooses its own grouping.

### Where the time goes

Two documents sit away from the ~1.7x that the rest cluster around, and both say
the same thing: the gap is the JPEG decoder.

**nasa-sls-fact-sheet** is 14 subsampled JPEGs, 2.2 M pixels. Decoding them is
131 ms of Huffman and IDCT plus 82 ms of upsampling and colour transform, where
`zune-jpeg` — a SIMD decoder — does the whole conversion in 58 ms. In monochrome
the ratio looks worse still (17x) but for an arithmetic reason: the 1-bit output
compresses so well that the Rust build's own run drops to 21 ms, while the port
still has the same JPEGs to decode.

**europe-map** is one page holding 22.6 MB of vector content. Half the port's
2.4 s is libz compressing the rewritten stream — work the Rust build does too —
and the other half is the content-stream rewriter, about 4x the Rust one.

On documents that are mostly structure and operators rather than image data, the
compiled Ruby lands within a factor of two of the Rust build.


## What the port taught me about Spinel

The first working version was 1.7× to 15× slower than Rust. Getting to the
numbers above was four changes, and three of them are Spinel-specific enough to
be worth writing down.

**A mutable String passed down a recursive call is copied at every frame.** The
serializer was written the obvious way — `write_obj(out, obj)` recursing into
`write_dict(out, d)` — and cost 634 ms to emit 308 KB, 14.6 s for 877 KB:
quadratic in the number of objects, 6.2 GB of String allocation for a 336 KB
input. Holding the bytes in an object's ivar instead (`Buf`) made the same work
2.9 ms and 9.9 ms — 218× and 1475×. A directly self-recursive method is worse
than slow: the appends are lost outright.

```ruby
module W
  def self.rec(out, depth)
    out << "x"
    return if depth == 0
    rec(out, depth - 1)
  end
end
a = String.new
20000.times { W.rec(a, 10) }
a.bytesize   # => 0 under spinel (2026.09.12), 220000 under CRuby
```

**`IO::Buffer` handed to an FFI call crashes the collector.** The first libz
binding passed `IO::Buffer`s as `:ptr` arguments, which the FFI documentation
invites. It segfaulted inside `sp_gc_collect` on about a quarter of runs, in
release and debug builds alike, and freeing the buffers eagerly did not help.
Letting the C side own its buffer and returning the result as `:binstr` — whose
byte count rides `sp_ffi_bin_len` — is both correct and faster; 60 consecutive
runs, no crash.

**`String#index` and `#rindex` count characters.** That is Ruby's own semantics
and not a Spinel quirk, but it bites hard in a PDF parser: the bytes of a PDF are
not valid UTF-8, and a string built by appending is not tagged binary the way
`File.binread`'s result is, so `rindex("startxref")` answered 468 where the byte
offset was 476 — 8 multi-byte sequences earlier in the file. `sumi/buf.rb`'s
`Bytes.index` / `Bytes.rindex` scan bytes and do not care how a string is
tagged.

The fourth change was ordinary: the content-stream lexer allocated a `Token`
object and a `byteslice` per token, which on the map's 22.6 MB of content is
millions of each. Scanning into `@kind` / `@tstart` / `@tstop` and keeping the
operands in three parallel Integer arrays removed all of it. The JPEG assembler
was doing two integer divisions per component per pixel for subsampling;
precomputing a row and column map per image cut that phase from 281 ms to 82 ms.

Two smaller notes:

- An array built as `[nil, nil, nil, nil]` and later filled with objects is a
  boxed container, and a method call on a value read back out of it fails with
  `undefined method '…' for unknown`. A `Hash` filled on demand keeps the slot's
  type known.
- `obj.attr += 1` is rejected (`unsupported expression: CallOperatorWriteNode`);
  write `obj.attr = obj.attr + 1`.
- Building with `-O3` instead of the default `-O2` is worth about 8-10% here.

## Reproducing

```sh
git clone https://github.com/champierre/sumi.git rust-sumi
cd rust-sumi && cargo build --release && python3 bench/fetch.py && cd ..
cd sumi && spin build && spin test && cd ..
./bench/parity.sh
python3 bench/compare.py --runs 10 --warmup 2 --mode grayscale
python3 bench/compare.py --runs 10 --warmup 2 --mode monochrome
```

`bench/fetch.py` copies the two invoices out of the sumi repository and
downloads four public-domain PDFs from Wikimedia Commons.

For the 405-document check, fetch the corpus with the sumi repository's own
harness first — it lands in `rust-sumi/validation/corpus/` and is about 1.4 GB,
so delete it when you are done:

```sh
python3 rust-sumi/validation/fetch_corpus.py --count 400
python3 bench/corpus.py --render --dpi 40 --pages 2 --mode grayscale
python3 bench/corpus.py --mode monochrome
```
