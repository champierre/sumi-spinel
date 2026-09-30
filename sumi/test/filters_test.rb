# Stream filters and the /DecodeParms predictors.
require "sumi"

include Sumi

def check(label, ok)
  puts "#{ok ? 'ok' : 'FAIL'} #{label}"
end

check("ASCIIHex", Filters.ascii_hex("48656C6C6F>") == "Hello")
check("ASCIIHex odd tail", Filters.ascii_hex("4865 6C6C 6F7>") == "Hello\x70")
check("ASCII85", Filters.ascii85("87cURD_*#4DfTZ)~>") == "Hello, World")
check("ASCII85 z", Filters.ascii85("z~>") == "\0\0\0\0")
check("RunLength", Filters.run_length("\x02abc\xfeZ\x80") == "abcZZZ")

round = Filters.inflate(Filters.flate("sumi" * 1000))
check("flate round trip", round == "sumi" * 1000)
# Compared byte by byte: a literal holding \xff is UTF-8 while the decoded
# bytes are binary, and String#== is false across those encodings under CRuby.
binary = "\0\1\2\xff\0"
round = Filters.inflate(Filters.flate(binary))
same = round.bytesize == binary.bytesize
i = 0
while i < binary.bytesize
  same = false unless round.getbyte(i) == binary.getbyte(i)
  i += 1
end
check("flate binary round trip", same)

# PNG up-predictor: each row adds the one above.
rows = "\x02\x01\x02\x03" + "\x02\x01\x01\x01"
check("PNG predictor up",
      Filters.unpredict(rows, 12, 1, 8, 3) == "\x01\x02\x03\x02\x03\x04")
# PNG sub-predictor: each byte adds the one to its left.
check("PNG predictor sub",
      Filters.unpredict("\x01\x01\x01\x01", 12, 1, 8, 3) == "\x01\x02\x03")
# TIFF predictor 2.
check("TIFF predictor",
      Filters.unpredict("\x01\x01\x01", 2, 1, 8, 3) == "\x01\x02\x03")
