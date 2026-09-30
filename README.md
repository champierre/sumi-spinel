# sumi-spinel

[English](README.en.md) | 日本語

[champierre/sumi](https://github.com/champierre/sumi) は、PDF を画像化せずに
色指定だけを書き換えてグレースケール／白黒 2 値に変換する Rust 製のツールです。

これはその sumi を、Matz の AOT Ruby コンパイラ
[Spinel](https://github.com/matz/spinel) が扱う Ruby のサブセットで書き直したものと、
Rust 版との比較結果です。

```
sumi-spinel/
  sumi/            移植版。ライブラリ・CLI・テストを含む spin パッケージ
  rust-sumi/       比較対象の champierre/sumi（clone してビルドする。リポジトリには含めない）
  bench/
    compare.py     ベンチマーク: rust / spinel / 同じコードを CRuby で動かした場合
    parity.sh      整合性チェック: 全 fixture で --report json が一致するか
    corpus.py      実世界 405 件の PDF での差分比較
    results-*.json, corpus-*.json
```

## ビルドと実行

```sh
# 比較対象を clone してビルド
git clone https://github.com/champierre/sumi.git rust-sumi
cd rust-sumi && cargo build --release && cd ..

# 移植版（spinel と spin に PATH が通っていること、zlib のヘッダが必要）
cd sumi && spin build && cd ..

sumi/build/bin/sumi input.pdf -o output.pdf --mode grayscale
```

引数・メッセージ・終了コード・`--report json` はすべて Rust 版と同じです。

## 移植した範囲

Rust 版がやっていることを、同じ手順で全部やります。Rust 版は 3 つのライブラリ
（PDF オブジェクトモデルの `lopdf`、DEFLATE の `flate2`、`/DCTDecode` 画像の
`zune-jpeg`）に依存していて、そのうち 1 番目と 3 番目は自前で書き起こしました。

- **PDF リーダー** — 相互参照テーブルと相互参照ストリーム、ハイブリッド形式、
  オブジェクトストリーム、増分更新、そして壊れた相互参照表が取りこぼした
  オブジェクトを拾うためのファイル走査
- **PDF ライター** — オブジェクトストリームと相互参照ストリーム。Rust 版が書く
  PDF 1.5 と同じ形
- **フィルタ** — Flate（PNG / TIFF 予測子つき）、LZW、ASCIIHex、ASCII85、RunLength
- **JPEG デコーダ** — ベースラインとプログレッシブ（SOF0/SOF1/SOF2）、任意の
  サブサンプリング、リスタート間隔、Adobe APP14 マーカー
- **変換本体** — 色空間（ICCBased、Indexed、Separation、DeviceN、Lab、Pattern）、
  PDF 関数（サンプル型・指数型・スティッチング型・PostScript 計算機）、
  コンテンツストリームの書き換え、画像とインライン画像の変換、シェーディングの
  再サンプリング、透明グループ、Type 3 グリフ、注釈、AcroForm フィールド

DEFLATE だけは自前で書いていません。`sumi/zlibffi.rb` が Spinel の FFI で
システムの libz を呼びます。Rust 版も DEFLATE ライブラリをリンクしているので、
比較したいのは「2 つのプログラム」であって「2 つの DEFLATE 実装」ではないからです。
（Spinel には独自実装の `zlib` パッケージが同梱されていますが、圧縮済みデータで
約 5%、地図のコンテンツストリームで 37% ほど出力が大きくなり、出力サイズの比較が
成り立たなくなります。）

それ以外は素の Ruby です。FFI モジュールは `if RUBY_ENGINE == "spinel"` の中にあり、
Spinel は解析前にこの分岐を落とすので、CRuby でも同じソースがそのまま動きます。
`spin test` はこれを利用していて、CRuby を正解役にして、コンパイル済みバイナリと
インタプリタの出力が一致することを各スナップショットが保証しています。
後述のベンチマークの 3 列目も同じ仕組みです。

## 出力は同じか

`bench/` に 3 つのチェックがあります。

### fixture 全件 × 全オプション

`bench/parity.sh` は、リポジトリの fixture・サンプル・ベンチマーク入力の計 12 件を、
6 通りのオプション（グレースケール、モノクロ、モノクロ＋ディザ、colorimetric、
非既定のしきい値、`--strict`）で両方のバイナリにかけ、`--report json` 全体と
終了コードを比較します。

**72 件中 72 件が一致**しました。ページ数・コンテンツストリーム数・色演算子数・
画像数・シェーディング数、警告の文言と回数、終了コードまで同じです。

### 実世界の PDF 405 件

`bench/corpus.py` は、sumi リポジトリ自身の検証ハーネスが集めるコーパス
（Wikimedia Commons から 20 の分野軸で集めたパブリックドメイン PDF 400 件＋
リポジトリの fixture、合計 1.4 GB）に対して両方を走らせ、`--report json` と
終了コードを比べ、さらに両方の出力を描画して画素単位で差分を取ります。

```
405 PDFs, mode grayscale
report identical: 404/405
rust exit codes: {0: 400, 3: 1, 4: 4}
rendered: 400 compared, 200 pixel-identical, mean difference 0.0380/255, worst pixel 221

405 PDFs, mode monochrome
report identical: 404/405
```

**半数の文書は描画結果が 1 画素も違わず**、文書ごとの平均差分の中央値は 0、
差が 50/255 を超える画素を持つ文書は 400 件中 2 件だけです（どちらも後述の 2 つの原因）。

レポートが食い違った 1 件（両モードとも同じ文書）は壊れた 76 ページの PDF で、
poppler も構文エラーを出します。`lopdf` はページが使うオブジェクトを 1 つ読めずに
ファイルごと拒否しますが、移植版はそれを読んで変換します。その出力には
**76 ページのどこにも色が残っていません**。

ページ数についても、405 件中 404 件で poppler と一致します。例外はこの壊れた
ファイルで、ページツリーをたどると 69、poppler 独自の復旧処理では 76 になります。

### 差分の原因は 2 つだけ

1. **JPEG デコーダの丸めが `zune-jpeg` と違う。** 請求書の 300×120 のロゴでは、
   デコード後のグレー値の 21% が違いますが、**そのすべてが 255 階調で 1 だけ**の差です。
   libjpeg（ImageMagick 経由）と突き合わせると、ベンチマーク中のどの `/DCTDecode`
   画像でも平均絶対誤差 0.23% 以内に収まります。モノクロモードでしきい値の近くに
   ある画素は ±1 で白黒が反転するので、モノクロの「max」欄は 255 になりますが、
   平均は 0.04/255 程度のままです。

2. **移植版は数値の書き方をそのまま残し、Rust 版は `f32` を経由して丸める。**
   `lopdf` は実数を `f32` に読んで印字し直すので、Chrome が書いた
   `/FontMatrix [.00100000005 …]` は `0.001` に、`/MediaBox` の `841.91998` は
   `841.92` になります。移植版は読んだトークンをそのまま書きます。どちらも同じ
   `f32` の値ですが、poppler は double として読むので、グリフの縁が 1 画素未満
   ずれます。どちらの原因もない文書（インフォグラフィックと地図）では、
   **2 つの出力は画素単位で完全に一致**します。

### 意図的に違えているところ

- **壊れたファイル。** `lopdf` が相互参照表を読めずに諦める
  （`invalid PDF: failed parsing cross reference table`、終了コード 3）ところで、
  移植版はファイル中の `N G obj` 宣言を走査して見つかったものを変換します。
  poppler をはじめ多くのビューアと同じ振る舞いです。壊した PDF 2200 件のうち
  122 件は Rust 版が拒否し、移植版は変換しました。ただし sumi の「内容を黙って
  失わない」という約束があるので、復旧したことは警告として報告し、`--strict` では
  従来どおり拒否します。

  ```
  sumi: warning: the cross-reference table could not be read; the file was
  rebuilt from the objects found in it
  ```

  読めるオブジェクトの中でストリームが切れている場合は内容の欠落そのものです。
  chrome の請求書を半分の長さに切って変換すると、ページ・コンテンツストリーム・
  色演算子はすべて復旧しましたが、描画結果の 0.2〜0.4% の画素が元の変換と違いました。
- **12bit JPEG** は変換せず未対応として報告します。YCCK（Adobe CMYK）JPEG は
  Rust 版のソースが説明している理由で、両方とも変換しません。
- 壊れた JPEG に対する拒否の文言は両者で違います
  （`bad Huffman value in JPEG` と zune-jpeg の `Bad Huffman Table`）。
  どちらも画像を色のまま残して警告します。

### 頑健性

12 件の fixture すべてに対して、切り詰め・ランダムなバイト反転・ゼロ埋め・
チャンクの貼り替え・ゴミの挿入をかけた 2200 件の壊れた PDF を移植版に通しましたが、
**クラッシュ・未処理例外・タイムアウトはいずれも 0 件**でした。
（最初の小規模な回で実際のバグが 2 つ出て、修正済みです。壊れたハフマン表が
DC デコーダに 64 を超えるシフト幅を渡しうる件と、相互参照ストリームの `/W` が
壊れていると整数に収まらない幅のフィールドを要求しうる件。）

## ベンチマーク

`bench/compare.py`。上流の `bench/bench.py` と同じ方法で、各ツールをアプリケーションが
呼ぶのと同じようにコマンドとして実行し、実時間とピーク RSS を `/usr/bin/time` から取り、
そのあと出力を poppler で検査して色の残りとテキスト抽出を確認します。
ウォームアップ 2 回のあと 10 回実行した中央値。`colored=0` と `text=1.000` は
全ツール・全入力で成立しました。

### グレースケール（`--mode grayscale`）

AMD Ryzen 7 6800H、Omarchy 4.0.1（Linux 7.1.9）、gcc 16.2.1、rustc 1.98.0、
CRuby 3.4.10、spinel a6c990a。

| 入力 | ページ | rust | spinel | CRuby | spinel / rust | spinel と CRuby |
|---|---:|---:|---:|---:|---:|---:|
| invoice.pdf（0.34 MB） | 2 | 26 ms | 53 ms | 391 ms | 2.07 倍 | 7.4 倍速い |
| equal-pay-infographic.pdf（0.30 MB） | 1 | 37 ms | 63 ms | 304 ms | 1.71 倍 | 4.9 倍速い |
| nasa-sls-fact-sheet.pdf（0.30 MB） | 2 | 58 ms | 376 ms | 2463 ms | 6.46 倍 | 6.6 倍速い |
| invoice-50pages.pdf（1.0 MB） | 50 | 85 ms | 146 ms | 902 ms | 1.73 倍 | 6.2 倍速い |
| communia-poster.pdf（5.9 MB） | 1 | 593 ms | 1046 ms | 4311 ms | 1.76 倍 | 4.1 倍速い |
| europe-map.pdf（6.7 MB） | 1 | 1575 ms | 2427 ms | 9609 ms | 1.54 倍 | 4.0 倍速い |
| **幾何平均** | | | | | **2.18 倍** | **5.4 倍速い** |

同じソースを CRuby で動かすと Rust 版の 11.7 倍かかります。

### モノクロ（`--mode monochrome`）

| 入力 | rust | spinel | CRuby | spinel / rust |
|---|---:|---:|---:|---:|
| invoice.pdf | 25 ms | 53 ms | 398 ms | 2.13 倍 |
| equal-pay-infographic.pdf | 36 ms | 62 ms | 306 ms | 1.72 倍 |
| nasa-sls-fact-sheet.pdf | 21 ms | 364 ms | 2664 ms | 17.25 倍 |
| invoice-50pages.pdf | 84 ms | 145 ms | 915 ms | 1.74 倍 |
| communia-poster.pdf | 653 ms | 1252 ms | 5686 ms | 1.92 倍 |
| europe-map.pdf | 1575 ms | 2428 ms | 9552 ms | 1.54 倍 |
| **幾何平均** | | | | **2.62 倍** |

### ピークメモリ（グレースケール）

| 入力 | rust | spinel | CRuby |
|---|---:|---:|---:|
| invoice.pdf | 14.7 MB | 21.4 MB | 29.1 MB |
| equal-pay-infographic.pdf | 6.8 MB | 13.8 MB | 19.6 MB |
| nasa-sls-fact-sheet.pdf | 8.1 MB | 33.5 MB | 39.0 MB |
| invoice-50pages.pdf | 30.5 MB | 54.7 MB | 46.9 MB |
| communia-poster.pdf | 31.7 MB | 65.0 MB | 55.1 MB |
| europe-map.pdf | 72.8 MB | 113.2 MB | 105.5 MB |

出力サイズはどの入力でも Rust 版の 3% 以内（-3.0%〜+0.3%、6 件中 4 件は移植版の方が
小さい）です。両方とも同じ PDF 1.5 の形を同じ DEFLATE で書くからで、残りの差は
オブジェクトストリームの詰め方（移植版は 200 個ずつ、`lopdf` は独自の分け方）です。

### どこで時間を使っているか

ほかがだいたい 1.7 倍前後に固まっている中で、2 件だけ離れています。どちらも
原因は同じで、JPEG デコーダです。

**nasa-sls-fact-sheet** はサブサンプリングされた JPEG が 14 枚、220 万画素です。
その復号にハフマンと IDCT で 131 ms、アップサンプリングと色変換で 82 ms かかります。
SIMD デコーダである `zune-jpeg` は変換全体を 58 ms で終えます。モノクロでは比が
さらに悪く見えますが（17 倍）、これは算術的な理由です。1bit 出力はよく縮むので
Rust 版自身の実行が 21 ms まで落ちる一方、移植版は同じ JPEG を復号する必要が
残るからです。

**europe-map** は 1 ページに 22.6 MB のベクターコンテンツが入っています。移植版の
2.4 秒のうち半分は、書き換えたストリームを libz が圧縮する時間（Rust 版も同じことを
します）で、残り半分がコンテンツストリームの書き換え、Rust 版のおよそ 4 倍です。

画像データよりも構造と演算子が主体の文書では、コンパイルされた Ruby は Rust 版の
2 倍以内に収まります。

## Spinel について分かったこと

最初に動いたバージョンは Rust 比 1.7〜15 倍でした。上の数字までは 4 つの変更で、
そのうち 3 つは Spinel 固有で書き留めておく価値があります。

**可変な String を再帰呼び出しの引数で渡すと、フレームごとにコピーされます。**
シリアライザは素直に `write_obj(out, obj)` が `write_dict(out, d)` に再帰する形で
書いていて、308 KB の出力に 634 ms、877 KB に 14.6 秒かかりました。オブジェクト数に
対して二乗で、336 KB の入力に対して String の割り当てが 6.2 GB です。バイト列を
オブジェクトの ivar に持たせる（`Buf`）と、同じ処理が 2.9 ms と 9.9 ms になりました。
218 倍と 1475 倍です。直接の自己再帰の場合は遅いだけでは済まず、追記が丸ごと
失われます。

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
a.bytesize   # => spinel (2026.09.12) では 0、CRuby では 220000
```

**`IO::Buffer` を FFI 呼び出しに渡すと GC が落ちます。** 最初の libz バインディングは
FFI のドキュメントが勧めるとおり `IO::Buffer` を `:ptr` 引数で渡していました。
release ビルドでも debug ビルドでも、4 回に 1 回ほど `sp_gc_collect` の中で segfault
します。バッファを明示的に `free` しても変わりませんでした。C 側に自前のバッファを
持たせ、結果を `:binstr`（バイト数は `sp_ffi_bin_len` に載る）で返すと、正しくなり
速くもなりました。連続 60 回実行でクラッシュなしです。

**`String#index` と `#rindex` は文字単位で数えます。** これは Ruby 本来の意味論で
Spinel の癖ではありませんが、PDF パーサではよく効きます。PDF のバイト列は正しい
UTF-8 ではなく、追記で組み立てた文字列は `File.binread` の結果のようにバイナリとして
タグ付けされていないので、`rindex("startxref")` がバイト位置 476 に対して 468 を
返しました。ファイル中でそれより前に多バイト列が 8 個あったからです。
`sumi/buf.rb` の `Bytes.index` / `Bytes.rindex` はバイトを走査するので、
文字列のタグ付けに左右されません。

4 つ目は普通の最適化です。コンテンツストリームのレキサはトークンごとに `Token`
オブジェクトと `byteslice` を作っていて、地図の 22.6 MB のコンテンツでは何百万個にも
なります。`@kind` / `@tstart` / `@tstop` に読み込む形にして、オペランドを 3 本の
Integer 配列で持つと全部なくなりました。JPEG の組み立ては、サブサンプリングのために
画素ごと・成分ごとに整数除算を 2 回していたので、画像ごとに行と列の対応表を
先に作って 281 ms から 82 ms になりました。

細かい点を 2 つ:

- `[nil, nil, nil, nil]` として作ってから後でオブジェクトを入れた配列はボックス化
  された入れ物になり、そこから読み出した値へのメソッド呼び出しは
  `undefined method '…' for unknown` で失敗します。必要に応じて埋める `Hash` なら
  スロットの型が分かったままになります。
- `obj.attr += 1` は拒否されます
  （`unsupported expression: CallOperatorWriteNode`）。
  `obj.attr = obj.attr + 1` と書きます。
- 既定の `-O2` ではなく `-O3` でビルドすると、ここでは 8〜10% ほど速くなります。

## 再現手順

```sh
git clone https://github.com/champierre/sumi.git rust-sumi
cd rust-sumi && cargo build --release && python3 bench/fetch.py && cd ..
cd sumi && spin build && spin test && cd ..
./bench/parity.sh
python3 bench/compare.py --runs 10 --warmup 2 --mode grayscale
python3 bench/compare.py --runs 10 --warmup 2 --mode monochrome
```

`bench/fetch.py` は sumi リポジトリから請求書 2 件をコピーし、Wikimedia Commons
からパブリックドメインの PDF を 4 件ダウンロードします。

405 件のチェックをするには、先に sumi リポジトリ自身のハーネスでコーパスを
取得します。`rust-sumi/validation/corpus/` に約 1.4 GB 置かれるので、終わったら
消してください。

```sh
python3 rust-sumi/validation/fetch_corpus.py --count 400
python3 bench/corpus.py --render --dpi 40 --pages 2 --mode grayscale
python3 bench/corpus.py --mode monochrome
```
