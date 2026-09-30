# PDF function evaluation, mirroring the Rust crate's unit tests.
require "sumi"

include Sumi

def check(label, ok)
  puts "#{ok ? 'ok' : 'FAIL'} #{label}"
end

def ps(code, inputs, outputs, input)
  f = Function.new(4)
  d = []
  i = 0
  while i < inputs
    d << 0.0
    d << 1.0
    i += 1
  end
  r = []
  i = 0
  while i < outputs
    r << 0.0
    r << 1.0
    i += 1
  end
  f.domain = d
  f.range = r
  f.program = Ps.parse(code)
  f.eval(input)
end

# A typical spot colour: tint -> CMYK.
out = ps("{ dup 0.2 mul exch dup 0.9 mul exch 0.8 mul 0 }", 1, 4, [0.5])
expected = [0.1, 0.45, 0.4, 0.0]
ok = out.length == 4
i = 0
while i < 4 && ok
  ok = false if (out[i] - expected[i]).abs > 1e-9
  i += 1
end
check("postscript tint transform", ok)

check("ifelse true", ps("{ 0.5 gt { 1 } { 0 } ifelse }", 1, 1, [0.7]) == [1.0])
check("ifelse false", ps("{ 0.5 gt { 1 } { 0 } ifelse }", 1, 1, [0.2]) == [0.0])
check("roll", ps("{ 1 2 3 3 1 roll pop pop }", 1, 1, [0.0]) == [1.0])
check("dup add", ps("{ pop 0.25 dup add }", 1, 1, [0.0]) == [0.5])

# Exponential and stitching.
red = Function.new(2)
red.domain = [0.0, 1.0]
red.c0 = [1.0, 0.0, 0.0]
red.c1 = [0.0, 0.0, 1.0]
red.nexp = 1.0
check("exponential midpoint", red.eval([0.5]) == [0.5, 0.0, 0.5])

stitched = Function.new(3)
stitched.domain = [0.0, 1.0]
stitched.functions = [red, red]
stitched.bounds = [0.5]
stitched.encode = [0.0, 1.0, 1.0, 0.0]
check("stitching first half", stitched.eval([0.25]) == [0.5, 0.0, 0.5])
check("stitching end", stitched.eval([1.0]) == [1.0, 0.0, 0.0])

# Sampled, with linear interpolation.
sampled = Function.new(0)
sampled.domain = [0.0, 1.0]
sampled.range = [0.0, 1.0]
sampled.size = [2]
sampled.bits = 8
sampled.encode = [0.0, 1.0]
sampled.decode = [0.0, 1.0]
sampled.samples = "\x00\xff"
check("sampled midpoint", (sampled.eval([0.5])[0] - 0.5).abs < 1e-9)
check("sampled end", sampled.eval([1.0]) == [1.0])
