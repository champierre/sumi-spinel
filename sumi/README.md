# sumi (Spinel port)

A rewrite of [champierre/sumi](https://github.com/champierre/sumi) — a PDF
grayscale/monochrome converter — in the Ruby subset that
[Spinel](https://github.com/matz/spinel) compiles ahead of time.

The CLI takes the same arguments as the Rust one and prints the same
`--report json`. See the top-level `../README.md` for the comparison against the
Rust build and for how the port was verified.

## Build

```sh
spin build          # -> build/bin/sumi
spin test           # differential tests: the compiled binary against CRuby
```

The port is plain Ruby apart from one engine-gated FFI module
(`sumi/zlibffi.rb`), so CRuby runs the same source:

```sh
ruby -I . bin/sumi.rb input.pdf -o output.pdf
```

That is what makes `spin test` a real test: CRuby is the oracle, and every
snapshot in `test/*.expected` is an agreement between the two engines.

## Layout

| file | what it holds |
|---|---|
| `sumi/obj.rb` | the PDF object model: one `Obj` class with a `kind` tag |
| `sumi/buf.rb` | `Buf`, the output byte buffer, and `Bytes`, byte-offset searching |
| `sumi/parser.rb` | the file-body tokenizer and object parser |
| `sumi/document.rb` | the cross-reference chain, object streams, recovery scan |
| `sumi/writer.rb` | serialization with object streams and a cross-reference stream |
| `sumi/filters.rb` | `/Filter` decoding and the `/DecodeParms` predictors |
| `sumi/zlibffi.rb` | DEFLATE: libz through Spinel's FFI, CRuby's zlib otherwise |
| `sumi/color.rb` | the colour maths, the conversion settings and the report |
| `sumi/colorspace.rb` | colour space resolution (ISO 32000-1, 8.6) |
| `sumi/function.rb`, `sumi/funcparse.rb`, `sumi/ps.rb` | PDF functions, types 0/2/3/4 |
| `sumi/clexer.rb` | the content stream tokenizer |
| `sumi/content.rb` | the content stream rewriter |
| `sumi/shading.rb` | resampling shadings into a gray function |
| `sumi/jpeg.rb` | a baseline JPEG decoder, for `/DCTDecode` images |
| `sumi/image.rb` | image XObjects and inline images |
| `sumi/convert.rb` | the document walk |
| `bin/sumi.rb` | the command line tool |
