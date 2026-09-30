# Colour maths, mirroring the Rust crate's unit tests.
require "sumi"

include Sumi

def near(a, b, tol)
  (a - b).abs < tol
end

def check(label, ok)
  puts "#{ok ? 'ok' : 'FAIL'} #{label}"
end

# Device conversions follow the PDF specification.
check("red luma", near(Color.rgb_to_gray(1.0, 0.0, 0.0, GRAY_LUMA), 0.30, 1e-9))
check("white luma", near(Color.rgb_to_gray(1.0, 1.0, 1.0, GRAY_LUMA), 1.0, 1e-9))
check("cmyk black", Color.cmyk_to_gray(0.0, 0.0, 0.0, 1.0) == 0.0)
check("cmyk white", Color.cmyk_to_gray(0.0, 0.0, 0.0, 0.0) == 1.0)
check("cyan", near(Color.cmyk_to_gray(1.0, 0.0, 0.0, 0.0), 0.70, 1e-9))

# Colorimetric follows sRGB luminance.
g = lambda { |r, gg, b| Color.rgb_to_gray(r, gg, b, GRAY_COLORIMETRIC) }
check("colorimetric red", near(g.call(1.0, 0.0, 0.0), 0.498, 1e-3))
check("colorimetric green", near(g.call(0.0, 1.0, 0.0), 0.862, 1e-3))
check("colorimetric blue", near(g.call(0.0, 0.0, 1.0), 0.298, 1e-3))
check("colorimetric mix", near(g.call(0.2, 0.4, 0.8), 0.418, 1e-3))
check("colorimetric black", g.call(0.0, 0.0, 0.0) == 0.0)
check("colorimetric white", near(g.call(1.0, 1.0, 1.0), 1.0, 1e-9))
neutral = true
[0.01, 0.2, 0.5, 0.8].each { |v| neutral = false unless near(g.call(v, v, v), v, 1e-9) }
check("colorimetric neutrals", neutral)
check("clamped", g.call(-1.0, 0.0, -0.5) == 0.0)
check("clamped high", near(g.call(2.0, 2.0, 2.0), 1.0, 1e-9))

# The integer paths agree with the float ones.
tables = Srgb8.new
agree = true
[[255, 0, 0], [0, 255, 0], [0, 0, 255], [12, 200, 99], [255, 255, 255]].each do |p|
  r = p[0]
  gg = p[1]
  b = p[2]
  luma = Color.rgb_to_gray(r / 255.0, gg / 255.0, b / 255.0, GRAY_LUMA) * 255.0
  agree = false if (Color.rgb8_to_gray(r, gg, b) - luma).abs > 1.0
  col = Color.rgb_to_gray(r / 255.0, gg / 255.0, b / 255.0, GRAY_COLORIMETRIC) * 255.0
  agree = false if (tables.gray(r, gg, b) - col).abs > 0.5
end
check("integer conversions match float", agree)
same = true
v = 0
while v < 256
  same = false unless tables.gray(v, v, v) == v
  v += 1
end
check("colorimetric greys round-trip", same)
check("cmyk8 black", Color.cmyk8_to_gray(0, 0, 0, 255) == 0)
check("cmyk8 white", Color.cmyk8_to_gray(0, 0, 0, 0) == 255)

# Monochrome thresholding.
tone = Tone.new(MODE_MONOCHROME, 0.5)
check("threshold low", tone.apply(0.3) == 0.0)
check("threshold high", tone.apply(0.7) == 1.0)
check("threshold 0.5 grey stays white",
      tone.apply(Color.rgb_to_gray(0.5, 0.5, 0.5, GRAY_LUMA)) == 1.0)

# Number formatting.
check("format 0.3", Color.format_number(0.3) == "0.3")
check("format 1.0", Color.format_number(1.0) == "1")
check("format 0.0", Color.format_number(0.0) == "0")
check("format tiny negative", Color.format_number(-0.00001) == "0")
check("format rounding", Color.format_number(0.123456) == "0.1235")
