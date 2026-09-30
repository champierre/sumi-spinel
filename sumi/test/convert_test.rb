# End-to-end conversion of PDFs built in the test itself.
require "sumi"

include Sumi

def check(label, ok)
  puts "#{ok ? 'ok' : 'FAIL'} #{label}"
end

# A one-page PDF whose content is `content`, with `extra` objects appended to
# the page's /Resources.
def build_pdf(content, resources)
  objects = []
  objects << "<</Type/Catalog/Pages 2 0 R>>"
  objects << "<</Type/Pages/Kids[3 0 R]/Count 1>>"
  objects << "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]" \
             "/Resources#{resources}/Contents 4 0 R>>"
  objects << "<</Length #{content.bytesize}>>\nstream\n#{content}\nendstream"
  out = String.new
  out << "%PDF-1.4\n"
  offsets = []
  i = 0
  while i < objects.length
    offsets << out.bytesize
    out << "#{i + 1} 0 obj\n" << objects[i] << "\nendobj\n"
    i += 1
  end
  xref = out.bytesize
  out << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
  offsets.each { |o| out << o.to_s.rjust(10, "0") << " 00000 n \n" }
  out << "trailer\n<</Size #{objects.length + 1}/Root 1 0 R>>\n"
  out << "startxref\n#{xref}\n%%EOF\n"
  out
end

def convert(pdf, settings)
  pair = Convert.convert_bytes(pdf, settings)
  [pair[0], pair[1]]
end

def page_content(pdf)
  doc = Document.load(pdf)
  out = String.new
  doc.pages.each do |page|
    doc.page_contents(page).each do |id|
      out << doc.decode_stream_obj(doc.objects[id], 1 << 28)
    end
  end
  out
end

grayscale = Settings.new
mono = Settings.new
mono.tone = Tone.new(MODE_MONOCHROME, 0.5)

# Device colours become DeviceGray.
pdf = build_pdf("1 0 0 rg 0 0 100 100 re f\n0 0 1 RG 5 w 10 10 m 90 90 l S", "<<>>")
result = convert(pdf, grayscale)
text = page_content(result[0])
check("fill becomes gray", text.include?("0.3 g"))
check("stroke becomes gray", text.include?("0.11 G"))
check("no rg left", !text.include?(" rg"))
check("no RG left", !text.include?(" RG"))
check("path kept", text.include?("0 0 100 100 re"))
check("two operators reported", result[1].color_operators == 2)
check("one page reported", result[1].pages == 1)
check("complete", result[1].complete?)

# CMYK, and the monochrome threshold.
pdf = build_pdf("0 0 0 1 k 0 0 50 50 re f", "<<>>")
check("cmyk black", page_content(convert(pdf, grayscale)[0]).include?("0 g"))
pdf = build_pdf("0.9 0.9 0.9 rg 0 0 50 50 re f", "<<>>")
check("light grey stays white in monochrome",
      page_content(convert(pdf, mono)[0]).include?("1 g"))
pdf = build_pdf("0.1 0.1 0.1 rg 0 0 50 50 re f", "<<>>")
check("dark grey becomes black in monochrome",
      page_content(convert(pdf, mono)[0]).include?("0 g"))

# An ICCBased space with three components is DeviceRGB.
resources = "<</ColorSpace<</Cs1[/ICCBased 5 0 R]>>>>"
pdf = build_pdf("/Cs1 cs 1 0 0 sc 0 0 10 10 re f", resources)
# The ICC stream object is missing, so the space falls back to a warning.
result = convert(pdf, grayscale)
check("missing ICC stream warns", !result[1].complete?)

# Text and strings are copied byte for byte.
content = "BT /F1 12 Tf 10 10 Td (Hello \\(world\\)) Tj ET 1 0 0 rg"
pdf = build_pdf(content, "<<>>")
text = page_content(convert(pdf, grayscale)[0])
check("text kept", text.include?("(Hello \\(world\\)) Tj"))

# An unknown colour space is reported rather than silently dropped.
pdf = build_pdf("/Nope cs 0.5 sc 0 0 10 10 re f", "<<>>")
result = convert(pdf, grayscale)
check("unknown space warns", result[1].warnings.length == 1)
check("warning names the space",
      result[1].warnings[0].include?("color space /Nope not found in resources"))

# A shading is resampled into a gray function.
resources = "<</Shading<</Sh0<</ShadingType 2/ColorSpace/DeviceRGB" \
            "/Coords[0 0 100 0]/Function<</FunctionType 2/Domain[0 1]" \
            "/C0[1 0 0]/C1[1 1 1]/N 1>>>>>>>>"
pdf = build_pdf("/Sh0 sh", resources)
result = convert(pdf, grayscale)
check("shading converted", result[1].shadings == 1)
doc = Document.load(result[0])
gray = false
samples = nil
doc.objects.each do |_, o|
  next unless o.stream?
  d = o.dict
  ft = d["FunctionType"]
  next unless ft && ft.to_i == 0
  samples = doc.decode_stream_obj(o, 1 << 28)
end
check("shading has 256 samples", !samples.nil? && samples.bytesize == 256)
check("shading starts at red's gray", !samples.nil? && samples.getbyte(0) == 77)
check("shading ends white", !samples.nil? && samples.getbyte(255) == 255)
