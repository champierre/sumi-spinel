# Serializes a document with object streams and a cross-reference stream
# (PDF 1.5), which is what the Rust version's writer does.

module Sumi
  module Writer
    # Keys that only describe the input's own cross-reference streams.
    XREF_KEYS = ["Prev", "XRefStm", "Type", "W", "Index", "Filter",
                 "DecodeParms", "Length"]

    def self.save(doc)
      prune(doc)
      compress_streams(doc)
      XREF_KEYS.each { |k| doc.trailer.delete(k) }

      version = doc.version
      version = "1.5" if version.nil? || version < "1.5"
      out = Buf.new
      out << "%PDF-" << version << "\n"
      out << "%\xe2\xe3\xcf\xd3\n"

      nums = doc.objects.keys.sort
      packable = []
      direct = []
      nums.each do |num|
        o = doc.objects[num]
        next if o.nil?
        if packable?(doc, num, o)
          packable << num
        else
          direct << num
        end
      end

      offsets = {}      # object number -> byte offset
      in_stream = {}    # object number -> [objstm number, index]

      direct.each do |num|
        offsets[num] = out.bytesize
        out << num.to_s << " 0 obj\n"
        write_obj(out, doc.objects[num])
        out << "\nendobj\n"
      end

      # Object streams: every packable object, in batches.
      batch = 200
      i = 0
      while i < packable.length
        group = packable[i, batch]
        i += batch
        header = Buf.new
        body = Buf.new
        idx = 0
        group.each do |num|
          header << num.to_s << " " << body.bytesize.to_s << " "
          write_obj(body, doc.objects[num])
          body << "\n"
          in_stream[num] = [0, idx]
          idx += 1
        end
        payload = header.to_s + body.to_s
        d = {}
        d["Type"] = Obj.name("ObjStm")
        d["N"] = Obj.int(group.length)
        d["First"] = Obj.int(header.bytesize)
        stm_num = doc.max_id + 1
        doc.max_id = stm_num
        group.each { |num| in_stream[num] = [stm_num, in_stream[num][1]] }
        compressed = Filters.flate(payload)
        d["Filter"] = Obj.name("FlateDecode")
        d["Length"] = Obj.int(compressed.bytesize)
        offsets[stm_num] = out.bytesize
        out << stm_num.to_s << " 0 obj\n"
        write_dict(out, d)
        out << "\nstream\n" << compressed << "\nendstream\nendobj\n"
      end

      # The cross-reference stream describes itself too.
      xref_num = doc.max_id + 1
      doc.max_id = xref_num
      xref_offset = out.bytesize
      size = xref_num + 1
      table = Buf.new
      n = 0
      while n < size
        if n == 0
          table << type_row(0, 0, 65535)
        elsif offsets.key?(n)
          table << type_row(1, offsets[n], 0)
        elsif in_stream.key?(n)
          loc = in_stream[n]
          table << type_row(2, loc[0], loc[1])
        elsif n == xref_num
          table << type_row(1, xref_offset, 0)
        else
          table << type_row(0, 0, 0)
        end
        n += 1
      end
      xd = {}
      doc.trailer.each { |k, v| xd[k] = v }
      xd["Type"] = Obj.name("XRef")
      xd["Size"] = Obj.int(size)
      xd["W"] = Obj.array([Obj.int(1), Obj.int(8), Obj.int(4)])
      compressed = Filters.flate(table.to_s)
      xd["Filter"] = Obj.name("FlateDecode")
      xd["Length"] = Obj.int(compressed.bytesize)
      out << xref_num.to_s << " 0 obj\n"
      write_dict(out, xd)
      out << "\nstream\n" << compressed << "\nendstream\nendobj\n"
      out << "startxref\n" << xref_offset.to_s << "\n%%EOF\n"
      out.to_s
    end

    def self.type_row(kind, field2, field3)
      s = String.new
      s << kind.chr
      i = 7
      while i >= 0
        s << ((field2 >> (i * 8)) & 0xff).chr
        i -= 1
      end
      i = 3
      while i >= 0
        s << ((field3 >> (i * 8)) & 0xff).chr
        i -= 1
      end
      s
    end

    def self.packable?(doc, num, obj)
      return false if obj.stream?
      enc = doc.trailer["Encrypt"]
      return false if enc && enc.ref? && enc.num == num
      true
    end

    # Flate-compresses streams stored without a filter, keeping each one only
    # if it gets smaller. XMP metadata is left alone.
    def self.compress_streams(doc)
      doc.objects.each do |_, o|
        next if o.nil? || !o.stream?
        next unless o.allow_compress
        d = o.dict
        next if d.nil?
        next if d.key?("Filter")
        next if d.key?("DecodeParms")
        ty = d["Type"]
        next if ty && ty.name? && ty.str == "Metadata"
        packed = Filters.flate(o.raw)
        next if packed.bytesize >= o.raw.bytesize
        d["Filter"] = Obj.name("FlateDecode")
        o.raw = packed
      end
    end

    # Drops objects nothing reachable from the trailer refers to.
    def self.prune(doc)
      keep = {}
      stack = []
      doc.trailer.each { |_, v| stack << v }
      while !stack.empty?
        o = stack.pop
        next if o.nil?
        if o.ref?
          next if keep.key?(o.num)
          keep[o.num] = true
          target = doc.objects[o.num]
          stack << target if target
          next
        end
        if o.array?
          o.items.each { |it| stack << it }
        elsif o.dict? || o.stream?
          o.dict.each { |_, v| stack << v } if o.dict
        end
      end
      doc.objects.keys.each do |num|
        doc.objects.delete(num) unless keep.key?(num)
      end
    end

    # ---- serialization ------------------------------------------------

    def self.write_obj(out, obj)
      case obj.kind
      when Obj::NULL then out << "null"
      when Obj::BOOL then out << (obj.num != 0 ? "true" : "false")
      when Obj::INT then out << obj.num.to_s
      when Obj::REAL
        # A real read from the input and never changed keeps its own spelling.
        out << (obj.str.nil? ? Reals.format(obj.real) : obj.str)
      when Obj::NAME
        out << "/" << Names.encode(obj.str)
      when Obj::STR
        write_string(out, obj)
      when Obj::REF
        out << obj.num.to_s << " " << obj.gen.to_s << " R"
      when Obj::ARRAY
        out << "["
        items = obj.items
        i = 0
        while i < items.length
          out << " " if i > 0
          write_obj(out, items[i])
          i += 1
        end
        out << "]"
      when Obj::DICT
        write_dict(out, obj.dict)
      when Obj::STREAM
        d = obj.dict
        d["Length"] = Obj.int(obj.raw.bytesize)
        write_dict(out, d)
        out << "\nstream\n" << obj.raw << "\nendstream"
      end
    end

    def self.write_dict(out, d)
      out << "<<"
      # A while loop over the keys rather than `d.each`: a block closing over
      # `out` boxes the buffer, and appending through the box copies it.
      keys = d.keys
      i = 0
      while i < keys.length
        k = keys[i]
        out << "/" << Names.encode(k) << " "
        write_obj(out, d[k])
        i += 1
      end
      out << ">>"
    end

    def self.write_string(out, obj)
      bytes = obj.str
      if obj.hex
        out << "<" << Hex.encode(bytes) << ">"
        return
      end
      # A literal string, escaping what must be escaped.
      out << "("
      i = 0
      n = bytes.bytesize
      while i < n
        c = bytes.getbyte(i)
        i += 1
        if c == 0x28
          out << "\\("
        elsif c == 0x29
          out << "\\)"
        elsif c == 0x5c
          out << "\\\\"
        elsif c == 0x0d
          out << "\\r"
        elsif c < 0x20 || c > 0x7e
          out << "\\" << octal3(c)
        else
          out << c.chr
        end
      end
      out << ")"
    end

    def self.octal3(c)
      s = String.new
      s << (0x30 + ((c >> 6) & 7)).chr
      s << (0x30 + ((c >> 3) & 7)).chr
      s << (0x30 + (c & 7)).chr
      s
    end
  end

  module Reals
    # A real with no exponent and no trailing zeros.
    def self.format(v)
      return "0" if v == 0.0 || v.nan? || v.infinite?
      rounded = (v * 1000000.0).round / 1000000.0
      return "0" if rounded == 0.0
      s = "%.6f" % rounded
      s = s.sub(/0+\z/, "")
      s = s.sub(/\.\z/, "")
      s
    end
  end
end
