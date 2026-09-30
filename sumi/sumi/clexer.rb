# Content stream tokenizer that keeps byte offsets, so the rewriter can replace
# individual operators and copy everything else verbatim.

module Sumi
  class Token
    NUMBER = 0
    NAME = 1
    STRING = 2
    ARRAY_OPEN = 3
    ARRAY_CLOSE = 4
    DICT_OPEN = 5
    DICT_CLOSE = 6
    # Operators, true/false/null and stray bytes.
    KEYWORD = 7

    attr_accessor :kind, :start, :stop

    def initialize(kind, start, stop)
      @kind = kind
      @start = start
      @stop = stop
    end
  end

  class ContentLexer
    attr_accessor :pos
    attr_reader :data, :kind, :tstart, :tstop

    def initialize(data)
      @data = data
      @pos = 0
      @len = data.bytesize
      @kind = -1
      @tstart = 0
      @tstop = 0
    end

    def text(token)
      @data.byteslice(token.start, token.stop - token.start)
    end

    def skip_space
      while @pos < @len
        b = @data.getbyte(@pos)
        if Lex.whitespace?(b)
          @pos += 1
        elsif b == 0x25
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

    # Scans the next token without allocating: the kind and the byte range land
    # in `kind`, `tstart` and `tstop`. A content stream holds millions of
    # tokens, and a Token object plus a byteslice for each is what used to
    # dominate the rewrite.
    def advance
      skip_space
      if @pos >= @len
        @kind = -1
        return false
      end
      data = @data
      start = @pos
      b = data.getbyte(start)
      kind = Token::KEYWORD
      stop = start + 1

      if b == 0x28 # '('
        depth = 0
        i = start
        while true
          if i >= @len
            kind = Token::STRING
            stop = @len
            break
          end
          c = data.getbyte(i)
          if c == 0x5c
            i += 2
          elsif c == 0x28
            depth += 1
            i += 1
          elsif c == 0x29
            depth -= 1
            i += 1
            if depth == 0
              kind = Token::STRING
              stop = i
              break
            end
          else
            i += 1
          end
        end
      elsif b == 0x3c && start + 1 < @len && data.getbyte(start + 1) == 0x3c
        kind = Token::DICT_OPEN
        stop = start + 2
      elsif b == 0x3c
        at = Bytes.index(data, ">", start)
        stop = at < 0 ? @len : at + 1
        kind = Token::STRING
      elsif b == 0x3e && start + 1 < @len && data.getbyte(start + 1) == 0x3e
        kind = Token::DICT_CLOSE
        stop = start + 2
      elsif b == 0x5b
        kind = Token::ARRAY_OPEN
      elsif b == 0x5d
        kind = Token::ARRAY_CLOSE
      elsif b == 0x2f
        i = start + 1
        i += 1 while i < @len && Lex.regular?(data.getbyte(i))
        kind = Token::NAME
        stop = i
      elsif Lex.delimiter?(b)
        kind = Token::KEYWORD
      else
        i = start
        i += 1 while i < @len && Lex.regular?(data.getbyte(i))
        stop = i
        kind = Numbers.real_range?(data, start, stop) ? Token::NUMBER : Token::KEYWORD
      end

      stop = @len if stop > @len
      @pos = stop
      @kind = kind
      @tstart = start
      @tstop = stop
      true
    end

    # Whether the current token's bytes are exactly `word`.
    def keyword?(word)
      n = @tstop - @tstart
      return false unless n == word.bytesize
      i = 0
      while i < n
        return false unless @data.getbyte(@tstart + i) == word.getbyte(i)
        i += 1
      end
      true
    end

    def token_text
      @data.byteslice(@tstart, @tstop - @tstart)
    end

    def current_token
      Token.new(@kind, @tstart, @tstop)
    end

    def next_token
      skip_space
      return nil if @pos >= @len
      data = @data
      start = @pos
      b = data.getbyte(start)
      kind = Token::KEYWORD
      stop = start + 1

      if b == 0x28 # '('
        depth = 0
        i = start
        while true
          if i >= @len
            kind = Token::STRING
            stop = @len
            break
          end
          c = data.getbyte(i)
          if c == 0x5c
            i += 2
          elsif c == 0x28
            depth += 1
            i += 1
          elsif c == 0x29
            depth -= 1
            i += 1
            if depth == 0
              kind = Token::STRING
              stop = i
              break
            end
          else
            i += 1
          end
        end
      elsif b == 0x3c && start + 1 < @len && data.getbyte(start + 1) == 0x3c
        kind = Token::DICT_OPEN
        stop = start + 2
      elsif b == 0x3c
        at = Bytes.index(data, ">", start)
        stop = at < 0 ? @len : at + 1
        kind = Token::STRING
      elsif b == 0x3e && start + 1 < @len && data.getbyte(start + 1) == 0x3e
        kind = Token::DICT_CLOSE
        stop = start + 2
      elsif b == 0x5b
        kind = Token::ARRAY_OPEN
        stop = start + 1
      elsif b == 0x5d
        kind = Token::ARRAY_CLOSE
        stop = start + 1
      elsif b == 0x2f
        i = start + 1
        i += 1 while i < @len && Lex.regular?(data.getbyte(i))
        kind = Token::NAME
        stop = i
      elsif Lex.delimiter?(b)
        kind = Token::KEYWORD
        stop = start + 1
      else
        i = start
        i += 1 while i < @len && Lex.regular?(data.getbyte(i))
        stop = i
        word = data.byteslice(start, stop - start)
        kind = Numbers.real?(word) ? Token::NUMBER : Token::KEYWORD
      end

      stop = @len if stop > @len
      @pos = stop
      Token.new(kind, start, stop)
    end

    # After the `ID` operator, finds the inline image data and the end of `EI`.
    # Returns [data_start, data_end, ei_end].
    def inline_image_data(expected_len)
      data = @data
      data_start = @pos + 1
      data_start = @len if data_start > @len

      if expected_len && expected_len > 0
        data_end = data_start + expected_len
        if data_end <= @len
          i = data_end
          i += 1 while i < @len && Lex.whitespace?(data.getbyte(i))
          if Bytes.match?(data, i, "EI") && (i + 2 >= @len || !Lex.regular?(data.getbyte(i + 2)))
            @pos = i + 2
            return [data_start, data_end, i + 2]
          end
        end
      end

      i = data_start
      while i + 1 < @len
        if data.getbyte(i) == 0x45 && data.getbyte(i + 1) == 0x49 &&
           (i == data_start || Lex.whitespace?(data.getbyte(i - 1))) &&
           (i + 2 >= @len || !Lex.regular?(data.getbyte(i + 2))) &&
           looks_like_content(i + 2)
          data_end = i > data_start ? i - 1 : i
          @pos = i + 2
          return [data_start, data_end, i + 2]
        end
        i += 1
      end
      @pos = @len
      [data_start, @len, @len]
    end

    def looks_like_content(from)
      i = from
      stop = from + 64
      stop = @len if stop > @len
      while i < stop
        c = @data.getbyte(i)
        return false unless (c >= 0x21 && c <= 0x7e) || Lex.whitespace?(c)
        i += 1
      end
      true
    end

    # Parses tokens into an Obj (used for inline image dictionaries).
    # `index` is a one-element array holding the cursor.
    def parse_object(tokens, index, depth)
      return nil if index[0] >= tokens.length
      token = tokens[index[0]]
      index[0] = index[0] + 1
      body = text(token)
      case token.kind
      when Token::NUMBER
        return nil unless Numbers.real?(body)
        return Obj.int(body.to_i) unless Bytes.include?(body, ".")
        o = Obj.real(Numbers.to_f(body))
        o.str = body
        return o
      when Token::NAME
        return Obj.name(Names.decode(body.byteslice(1, body.bytesize - 1)))
      when Token::STRING
        return Obj.string(CStrings.decode(body), false)
      when Token::KEYWORD
        return Obj.bool(true) if body == "true"
        return Obj.bool(false) if body == "false"
        return Obj.null if body == "null"
        return nil
      when Token::ARRAY_OPEN
        return nil if depth >= 16
        items = []
        while true
          return nil if index[0] >= tokens.length
          if tokens[index[0]].kind == Token::ARRAY_CLOSE
            index[0] = index[0] + 1
            break
          end
          v = parse_object(tokens, index, depth + 1)
          return nil if v.nil?
          items << v
        end
        return Obj.array(items)
      when Token::DICT_OPEN
        return nil if depth >= 16
        d = {}
        while true
          return nil if index[0] >= tokens.length
          t = tokens[index[0]]
          if t.kind == Token::DICT_CLOSE
            index[0] = index[0] + 1
            break
          end
          return nil unless t.kind == Token::NAME
          kt = text(t)
          key = Names.decode(kt.byteslice(1, kt.bytesize - 1))
          index[0] = index[0] + 1
          v = parse_object(tokens, index, depth + 1)
          return nil if v.nil?
          d[key] = v
        end
        return Obj.dictionary(d)
      end
      nil
    end
  end

  module CStrings
    # Decodes a literal `( … )` or hex `< … >` string token.
    def self.decode(body)
      if body.getbyte(0) == 0x3c
        out = String.new
        hi = -1
        i = 1
        n = body.bytesize
        while i < n
          c = body.getbyte(i)
          i += 1
          break if c == 0x3e
          v = Filters.hex_value(c)
          next if v < 0
          if hi < 0
            hi = v
          else
            out << ((hi << 4) | v).chr
            hi = -1
          end
        end
        out << (hi << 4).chr if hi >= 0
        return out
      end
      inner = body
      inner = inner.byteslice(1, inner.bytesize - 1) if inner.getbyte(0) == 0x28
      if inner.bytesize > 0 && inner.getbyte(inner.bytesize - 1) == 0x29
        inner = inner.byteslice(0, inner.bytesize - 1)
      end
      out = String.new
      i = 0
      n = inner.bytesize
      while i < n
        c = inner.getbyte(i)
        if c != 0x5c
          out << c.chr
          i += 1
          next
        end
        i += 1
        break if i >= n
        e = inner.getbyte(i)
        if e == 0x6e
          out << "\n"
        elsif e == 0x72
          out << "\r"
        elsif e == 0x74
          out << "\t"
        elsif e == 0x62
          out << 8.chr
        elsif e == 0x66
          out << 12.chr
        elsif e >= 0x30 && e <= 0x37
          v = 0
          k = 0
          while k < 3 && i < n
            c2 = inner.getbyte(i)
            break unless c2 >= 0x30 && c2 <= 0x37
            v = v * 8 + (c2 - 0x30)
            i += 1
            k += 1
          end
          out << (v & 0xff).chr
          next
        elsif e == 0x0d
          i += 1 if i + 1 < n && inner.getbyte(i + 1) == 0x0a
        elsif e == 0x0a
          nil
        else
          out << e.chr
        end
        i += 1
      end
      out
    end
  end

  # Serializes an object in content stream syntax (inline image dictionaries).
  module CWrite
    def self.write(out, obj)
      case obj.kind
      when Obj::NULL then out << "null"
      when Obj::BOOL then out << (obj.num != 0 ? "true" : "false")
      when Obj::INT then out << obj.num.to_s
      when Obj::REAL then out << Color.format_number(obj.real)
      when Obj::NAME
        out << "/"
        i = 0
        n = obj.str.bytesize
        while i < n
          c = obj.str.getbyte(i)
          if Lex.regular?(c) && c != 0x23 && c > 0x20 && c < 0x7f
            out << c.chr
          else
            out << "#" << Hex.byte(c)
          end
          i += 1
        end
      when Obj::STR
        out << "<" << Hex.encode(obj.str) << ">"
      when Obj::ARRAY
        out << "["
        items = obj.items
        i = 0
        while i < items.length
          out << " " if i > 0
          write(out, items[i])
          i += 1
        end
        out << "]"
      when Obj::DICT
        out << "<<"
        keys = obj.dict.keys
        i = 0
        while i < keys.length
          k = keys[i]
          write(out, Obj.name(k))
          out << " "
          write(out, obj.dict[k])
          i += 1
        end
        out << ">>"
      else
        # Not valid inside content streams.
        out << "null"
      end
    end
  end
end
