# Stream filters (ISO 32000-1, 7.4) and the /DecodeParms predictors.
module Sumi
  module Filters
    # Raised when a stream cannot be decoded; the caller turns it into a warning.
    class DecodeError < StandardError; end
    # Raised when a decoded stream would exceed the configured limit.
    class LimitError < StandardError; end
    # Raised for a construct sumi knowingly does not convert.
    class UnsupportedError < StandardError; end

    ABBREV = {
      "AHx" => "ASCIIHexDecode",
      "A85" => "ASCII85Decode",
      "LZW" => "LZWDecode",
      "Fl" => "FlateDecode",
      "RL" => "RunLengthDecode",
      "CCF" => "CCITTFaxDecode",
      "DCT" => "DCTDecode",
    }

    def self.full_name(name)
      ABBREV.fetch(name, name)
    end

    # Filters that hand back image samples rather than bytes the parser reads.
    def self.image_filter?(name)
      name == "DCTDecode" || name == "JPXDecode" ||
        name == "JBIG2Decode" || name == "CCITTFaxDecode"
    end

    DEFAULT_LEVEL = 6

    def self.flate(data, level = DEFAULT_LEVEL)
      Flate.compress(data, level)
    end

    def self.inflate(data)
      out = Flate.decompress(data, 0)
      return out unless out.nil?
      # Truncated or slightly malformed streams are common; a raw-DEFLATE read,
      # possibly past a bad header byte, is what viewers fall back to.
      out = Flate.decompress(data, 1)
      return out unless out.nil?
      skip = 1
      while skip < 3 && skip < data.bytesize
        out = Flate.decompress(data.byteslice(skip, data.bytesize - skip), 1)
        return out unless out.nil?
        skip += 1
      end
      raise DecodeError, "flate stream is corrupt"
    end

    def self.ascii_hex(data)
      out = String.new
      hi = -1
      i = 0
      n = data.bytesize
      while i < n
        c = data.getbyte(i)
        i += 1
        break if c == 0x3e # '>'
        v = hex_value(c)
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

    def self.hex_value(c)
      return c - 0x30 if c >= 0x30 && c <= 0x39
      return c - 0x41 + 10 if c >= 0x41 && c <= 0x46
      return c - 0x61 + 10 if c >= 0x61 && c <= 0x66
      -1
    end

    def self.ascii85(data)
      out = String.new
      group = []
      i = 0
      n = data.bytesize
      # An optional <~ prefix.
      i = 2 if n >= 2 && data.getbyte(0) == 0x3c && data.getbyte(1) == 0x7e
      while i < n
        c = data.getbyte(i)
        i += 1
        break if c == 0x7e # '~' ends the data
        next if c <= 0x20 || c == 0
        if c == 0x7a && group.empty? # 'z' is four zero bytes
          out << "\0\0\0\0"
          next
        end
        raise DecodeError, "bad ASCII85 byte" if c < 0x21 || c > 0x75
        group << (c - 0x21)
        if group.length == 5
          out << ascii85_group(group, 4)
          group = []
        end
      end
      unless group.empty?
        count = group.length - 1
        padded = group.dup
        padded << 84 while padded.length < 5
        out << ascii85_group(padded, count)
      end
      out
    end

    def self.ascii85_group(group, count)
      value = 0
      group.each { |g| value = value * 85 + g }
      bytes = String.new
      bytes << ((value >> 24) & 0xff).chr
      bytes << ((value >> 16) & 0xff).chr
      bytes << ((value >> 8) & 0xff).chr
      bytes << (value & 0xff).chr
      bytes.byteslice(0, count)
    end

    def self.run_length(data)
      out = String.new
      i = 0
      n = data.bytesize
      while i < n
        len = data.getbyte(i)
        i += 1
        break if len == 128
        if len < 128
          take = len + 1
          take = n - i if i + take > n
          out << data.byteslice(i, take)
          i += take
        else
          break if i >= n
          b = data.getbyte(i)
          i += 1
          count = 257 - len
          j = 0
          while j < count
            out << b.chr
            j += 1
          end
        end
      end
      out
    end

    def self.lzw_table
      table = []
      i = 0
      while i < 256
        table << i.chr
        i += 1
      end
      table << ""
      table << ""
      table
    end

    def self.lzw(data, early_change)
      out = String.new
      # Dictionary entries 0..255 are single bytes, 256 clear, 257 EOD.
      table = lzw_table
      width = 9
      prev = nil
      bitpos = 0
      total_bits = data.bytesize * 8
      while bitpos + width <= total_bits
        code = 0
        k = 0
        while k < width
          bit = bitpos + k
          byte = data.getbyte(bit >> 3)
          code = (code << 1) | ((byte >> (7 - (bit & 7))) & 1)
          k += 1
        end
        bitpos += width
        if code == 256
          table = lzw_table
          width = 9
          prev = nil
          next
        end
        break if code == 257
        entry = nil
        if code < table.length
          entry = table[code]
          entry = prev + prev.byteslice(0, 1) if code >= 258 && entry.bytesize == 0 && prev
        elsif prev
          entry = prev + prev.byteslice(0, 1)
        end
        raise DecodeError, "bad LZW code" if entry.nil?
        out << entry
        table << (prev + entry.byteslice(0, 1)) if prev
        prev = entry
        limit = early_change ? 1 : 0
        if table.length + limit >= 512 && width == 9
          width = 10
        elsif table.length + limit >= 1024 && width == 10
          width = 11
        elsif table.length + limit >= 2048 && width == 11
          width = 12
        end
      end
      out
    end

    # Undoes a /Predictor. `colors` components of `bpc` bits per row of `columns`.
    def self.unpredict(data, predictor, colors, bpc, columns)
      return data if predictor < 2
      bpp = ((colors * bpc) + 7) / 8
      bpp = 1 if bpp < 1
      row_len = (columns * colors * bpc + 7) / 8
      if predictor == 2
        return tiff_predictor(data, colors, bpc, columns)
      end
      # PNG predictors: each row is preceded by a filter-type byte.
      out = String.new
      prev = "\0" * row_len
      pos = 0
      n = data.bytesize
      while pos + 1 <= n
        ft = data.getbyte(pos)
        pos += 1
        break if pos >= n && row_len > 0
        take = row_len
        take = n - pos if pos + take > n
        row = data.byteslice(pos, take).bytes
        row << 0 while row.length < row_len
        pos += take
        case ft
        when 0
          # none
        when 1
          i = bpp
          while i < row_len
            row[i] = (row[i] + row[i - bpp]) & 0xff
            i += 1
          end
        when 2
          i = 0
          while i < row_len
            row[i] = (row[i] + prev.getbyte(i)) & 0xff
            i += 1
          end
        when 3
          i = 0
          while i < row_len
            left = i >= bpp ? row[i - bpp] : 0
            row[i] = (row[i] + ((left + prev.getbyte(i)) >> 1)) & 0xff
            i += 1
          end
        when 4
          i = 0
          while i < row_len
            a = i >= bpp ? row[i - bpp] : 0
            b = prev.getbyte(i)
            c = i >= bpp ? prev.getbyte(i - bpp) : 0
            p = a + b - c
            pa = (p - a).abs
            pb = (p - b).abs
            pc = (p - c).abs
            pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
            row[i] = (row[i] + pred) & 0xff
            i += 1
          end
        else
          raise DecodeError, "unknown PNG predictor #{ft}"
        end
        line = String.new
        row.each { |b| line << b.chr }
        out << line
        prev = line
        break if pos >= n
      end
      out
    end

    def self.tiff_predictor(data, colors, bpc, columns)
      return data unless bpc == 8
      row_len = columns * colors
      out = String.new
      pos = 0
      n = data.bytesize
      while pos < n
        take = row_len
        take = n - pos if pos + take > n
        row = data.byteslice(pos, take).bytes
        pos += take
        i = colors
        while i < row.length
          row[i] = (row[i] + row[i - colors]) & 0xff
          i += 1
        end
        line = String.new
        row.each { |b| line << b.chr }
        out << line
      end
      out
    end
  end
end
