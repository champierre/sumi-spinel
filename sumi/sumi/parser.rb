# Tokenizer and object parser for the PDF file body (ISO 32000-1, 7.3).

module Sumi
  module Lex
    def self.whitespace?(b)
      b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 || b == 0x0c || b == 0
    end

    def self.delimiter?(b)
      b == 0x28 || b == 0x29 || b == 0x3c || b == 0x3e || b == 0x5b ||
        b == 0x5d || b == 0x7b || b == 0x7d || b == 0x2f || b == 0x25
    end

    def self.regular?(b)
      !whitespace?(b) && !delimiter?(b)
    end

    def self.digit?(b)
      b >= 0x30 && b <= 0x39
    end
  end

  class Parser
    attr_accessor :pos
    attr_reader :data

    def initialize(data)
      @data = data
      @pos = 0
      @len = data.bytesize
    end

    def eof? = @pos >= @len

    def skip_space
      while @pos < @len
        b = @data.getbyte(@pos)
        if Lex.whitespace?(b)
          @pos += 1
        elsif b == 0x25 # '%'
          while @pos < @len
            c = @data.getbyte(@pos)
            break if c == 0x0a || c == 0x0d
            @pos += 1
          end
        else
          break
        end
      end
    end

    # The next run of regular characters, as a String.
    def read_regular
      start = @pos
      @pos += 1 while @pos < @len && Lex.regular?(@data.getbyte(@pos))
      @data.byteslice(start, @pos - start)
    end

    def peek_keyword(word)
      skip_space
      return false if @pos + word.bytesize > @len
      return false unless Bytes.match?(@data, @pos, word)
      after = @pos + word.bytesize
      after >= @len || !Lex.regular?(@data.getbyte(after))
    end

    def take_keyword(word)
      return false unless peek_keyword(word)
      @pos += word.bytesize
      true
    end

    def read_name
      @pos += 1 # '/'
      start = @pos
      @pos += 1 while @pos < @len && Lex.regular?(@data.getbyte(@pos))
      Names.decode(@data.byteslice(start, @pos - start))
    end

    def read_literal_string
      @pos += 1 # '('
      out = String.new
      depth = 1
      while @pos < @len
        b = @data.getbyte(@pos)
        @pos += 1
        if b == 0x5c # backslash
          break if @pos >= @len
          e = @data.getbyte(@pos)
          @pos += 1
          case e
          when 0x6e then out << "\n"
          when 0x72 then out << "\r"
          when 0x74 then out << "\t"
          when 0x62 then out << 8.chr
          when 0x66 then out << 12.chr
          when 0x0a then nil
          when 0x0d
            @pos += 1 if @pos < @len && @data.getbyte(@pos) == 0x0a
          else
            if e >= 0x30 && e <= 0x37
              v = e - 0x30
              k = 1
              while k < 3 && @pos < @len
                c = @data.getbyte(@pos)
                break unless c >= 0x30 && c <= 0x37
                v = v * 8 + (c - 0x30)
                @pos += 1
                k += 1
              end
              out << (v & 0xff).chr
            else
              out << e.chr
            end
          end
        elsif b == 0x28
          depth += 1
          out << "("
        elsif b == 0x29
          depth -= 1
          break if depth == 0
          out << ")"
        else
          out << b.chr
        end
      end
      out
    end

    def read_hex_string
      @pos += 1 # '<'
      out = String.new
      hi = -1
      while @pos < @len
        b = @data.getbyte(@pos)
        @pos += 1
        break if b == 0x3e # '>'
        v = Filters.hex_value(b)
        next if v < 0
        if hi < 0
          hi = v
        else
          out << ((hi << 4) | v).chr
          hi = -1
        end
      end
      out << (hi << 4).chr if hi >= 0
      out
    end

    # Parses one object. `resolver` (may be nil) is only used to look up a
    # stream's indirect /Length.
    def parse(depth = 0)
      skip_space
      return Obj.null if @pos >= @len || depth > 64
      b = @data.getbyte(@pos)
      case b
      when 0x2f # '/'
        return Obj.name(read_name)
      when 0x28 # '('
        return Obj.string(read_literal_string, false)
      when 0x3c # '<'
        if @pos + 1 < @len && @data.getbyte(@pos + 1) == 0x3c
          return parse_dict_or_stream(depth)
        end
        return Obj.string(read_hex_string, true)
      when 0x5b # '['
        @pos += 1
        items = []
        while true
          skip_space
          break if @pos >= @len
          if @data.getbyte(@pos) == 0x5d
            @pos += 1
            break
          end
          before = @pos
          items << parse(depth + 1)
          break if @pos == before
        end
        return Obj.array(items)
      when 0x5d, 0x3e, 0x7b, 0x7d, 0x29
        @pos += 1
        return Obj.null
      end

      word = read_regular
      return Obj.null if word.bytesize == 0
      return Obj.bool(true) if word == "true"
      return Obj.bool(false) if word == "false"
      return Obj.null if word == "null"

      if Numbers.integer?(word)
        value = word.to_i
        # `N G R` is a reference; `N G obj` starts an indirect object.
        save = @pos
        skip_space
        start2 = @pos
        if @pos < @len && Lex.digit?(@data.getbyte(@pos))
          word2 = read_regular
          if Numbers.integer?(word2)
            if take_keyword("R")
              return Obj.ref(value, word2.to_i)
            end
          end
          @pos = start2
        end
        @pos = save
        return Obj.int(value)
      end
      if Numbers.real?(word)
        o = Obj.real(Numbers.to_f(word))
        # The token as written, so an untouched number is copied verbatim.
        o.str = word
        return o
      end
      # Stray keyword.
      Obj.null
    end

    def parse_dict_or_stream(depth)
      @pos += 2 # '<<'
      d = {}
      while true
        skip_space
        break if @pos >= @len
        b = @data.getbyte(@pos)
        if b == 0x3e
          @pos += 1
          @pos += 1 if @pos < @len && @data.getbyte(@pos) == 0x3e
          break
        end
        unless b == 0x2f
          before = @pos
          parse(depth + 1)
          break if @pos == before
          next
        end
        key = read_name
        d[key] = parse(depth + 1)
      end
      skip_space
      return Obj.dictionary(d) unless peek_keyword("stream")
      @pos += 6
      # The keyword is followed by CRLF or LF.
      @pos += 1 if @pos < @len && @data.getbyte(@pos) == 0x0d
      @pos += 1 if @pos < @len && @data.getbyte(@pos) == 0x0a
      start = @pos
      length = -1
      lo = d["Length"]
      length = lo.num if lo && lo.int?
      if length >= 0 && start + length <= @len
        after = start + length
        probe = after
        probe += 1 while probe < @len && Lex.whitespace?(@data.getbyte(probe))
        if Bytes.match?(@data, probe, "endstream")
          @pos = probe + 9
          return Obj.stream(d, @data.byteslice(start, length))
        end
      end
      # /Length was missing, indirect or wrong: find the closing keyword.
      at = Bytes.index(@data, "endstream", start)
      if at < 0
        @pos = @len
        return Obj.stream(d, @data.byteslice(start, @len - start))
      end
      stop = at
      stop -= 1 if stop > start && @data.getbyte(stop - 1) == 0x0a
      stop -= 1 if stop > start && @data.getbyte(stop - 1) == 0x0d
      @pos = at + 9
      Obj.stream(d, @data.byteslice(start, stop - start))
    end
  end

  module Numbers
    def self.integer?(text)
      n = text.bytesize
      return false if n == 0
      i = 0
      digits = 0
      while i < n
        c = text.getbyte(i)
        if c >= 0x30 && c <= 0x39
          digits += 1
        elsif (c == 0x2b || c == 0x2d) && i == 0
          nil
        else
          return false
        end
        i += 1
      end
      digits > 0
    end

    # Accepts the shapes PDF allows: `.5`, `-3.`, `+7`, `4.25`.
    def self.real?(text)
      n = text.bytesize
      return false if n == 0
      digits = 0
      dots = 0
      i = 0
      while i < n
        c = text.getbyte(i)
        if c >= 0x30 && c <= 0x39
          digits += 1
        elsif c == 0x2e
          dots += 1
        elsif (c == 0x2b || c == 0x2d) && i == 0
          nil
        else
          return false
        end
        i += 1
      end
      digits > 0 && dots <= 1
    end

    # `real?` over a byte range, with no substring taken.
    def self.real_range?(data, start, stop)
      digits = 0
      dots = 0
      i = start
      while i < stop
        c = data.getbyte(i)
        if c >= 0x30 && c <= 0x39
          digits += 1
        elsif c == 0x2e
          dots += 1
        elsif (c == 0x2b || c == 0x2d) && i == start
          nil
        else
          return false
        end
        i += 1
      end
      digits > 0 && dots <= 1
    end

    def self.to_f(text)
      s = text
      s = s.byteslice(1, s.bytesize - 1) if s.getbyte(0) == 0x2b
      sign = 1.0
      if s.bytesize > 0 && s.getbyte(0) == 0x2d
        sign = -1.0
        s = s.byteslice(1, s.bytesize - 1)
      end
      s = "0" + s if s.bytesize > 0 && s.getbyte(0) == 0x2e
      s = s + "0" if s.bytesize > 0 && s.getbyte(s.bytesize - 1) == 0x2e
      return 0.0 if s.bytesize == 0
      sign * s.to_f
    end
  end

  module Names
    # `#xx` escapes inside a name.
    # Whether any byte of a name has to be written as `#xx`.
    def self.needs_escape?(text)
      i = 0
      n = text.bytesize
      while i < n
        c = text.getbyte(i)
        return true unless Lex.regular?(c) && c != 0x23 && c > 0x20 && c < 0x7f
        i += 1
      end
      false
    end

    def self.decode(raw)
      return raw unless Bytes.include?(raw, "#")
      out = String.new
      i = 0
      n = raw.bytesize
      while i < n
        c = raw.getbyte(i)
        if c == 0x23 && i + 2 < n
          hi = Filters.hex_value(raw.getbyte(i + 1))
          lo = Filters.hex_value(raw.getbyte(i + 2))
          if hi >= 0 && lo >= 0
            out << ((hi << 4) | lo).chr
            i += 3
            next
          end
        end
        out << c.chr
        i += 1
      end
      out
    end

    def self.encode(text)
      return text unless needs_escape?(text)
      out = String.new
      i = 0
      n = text.bytesize
      while i < n
        c = text.getbyte(i)
        if Lex.regular?(c) && c != 0x23 && c > 0x20 && c < 0x7f
          out << c.chr
        else
          out << "#" << Hex.byte(c)
        end
        i += 1
      end
      out
    end
  end

  module Hex
    DIGITS = "0123456789ABCDEF"

    def self.byte(b)
      DIGITS.byteslice((b >> 4) & 0xf, 1) + DIGITS.byteslice(b & 0xf, 1)
    end

    def self.encode(data)
      out = String.new
      i = 0
      n = data.bytesize
      while i < n
        out << byte(data.getbyte(i))
        i += 1
      end
      out
    end
  end
end
