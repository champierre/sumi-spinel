# The content stream tokenizer and the PDF string/name decoders.
require "sumi"

include Sumi

def check(label, ok)
  puts "#{ok ? 'ok' : 'FAIL'} #{label}"
end

NAMES = ["Number", "Name", "String", "[", "]", "<<", ">>", "Keyword"]

data = "1 0 0 rg (a(b)c\\)) Tj/F1 12 Tf <48656c> % comment\n[.5 -3.]TJ<</MCID 0>>BDC"
lexer = ContentLexer.new(data)
seen = []
while lexer.advance
  seen << NAMES[lexer.kind] + ":" + lexer.token_text
end
expected = [
  "Number:1", "Number:0", "Number:0", "Keyword:rg", "String:(a(b)c\\))",
  "Keyword:Tj", "Name:/F1", "Number:12", "Keyword:Tf", "String:<48656c>",
  "[:[", "Number:.5", "Number:-3.", "]:]", "Keyword:TJ",
  "<<:<<", "Name:/MCID", "Number:0", ">>:>>", "Keyword:BDC",
]
check("tokenizes operators, strings and names", seen == expected)

check("number .5", Numbers.to_f(".5") == 0.5)
check("number -.25", Numbers.to_f("-.25") == -0.25)
check("number 4.", Numbers.to_f("4.") == 4.0)
check("number +7", Numbers.to_f("+7") == 7.0)
check("not a number 1.2.3", !Numbers.real?("1.2.3"))
check("not a number -", !Numbers.real?("-"))

check("literal string escapes", CStrings.decode("(a\\(b\\)\\101\\n)") == "a(b)A\n")
check("hex string", CStrings.decode("<48 65 6c6>") == "Hel\x60")
check("name escapes", Names.decode("A#20B") == "A B")

# An inline image whose data contains the bytes `EI`.
data = "BI /W 2 /H 1 /BPC 8 /CS /G /F /Fl ID \x01EI\xff\x00 EI Q"
lexer = ContentLexer.new(data)
while lexer.advance
  break if lexer.keyword?("ID")
end
span = lexer.inline_image_data(nil)
check("inline image data", data.byteslice(span[0], span[1] - span[0]) == "\x01EI\xff\x00")
check("inline image tail", data.byteslice(span[2], data.bytesize - span[2]) == " Q")
