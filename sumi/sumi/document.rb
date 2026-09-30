# Loads a PDF: the cross-reference chain (tables and streams), object streams,
# and a recovery scan for files whose xref is wrong.

module Sumi
  class Document
    attr_accessor :objects, :trailer, :max_id, :version, :encrypted, :declared
    # Objects the cross-reference table pointed at but could not be read there,
    # and whether the chain produced no usable entries at all. Both mean the
    # file was repaired by scanning it, which the report says out loud.
    attr_accessor :repaired_objects, :repaired_xref

    def initialize
      @objects = {}       # object number -> Obj
      @trailer = {}        # name -> Obj
      @max_id = 0
      @version = "1.7"
      @encrypted = false
      @declared = {}       # object number -> true, as written in the file
      @repaired_objects = 0
      @repaired_xref = false
      @offsets = {}        # object number -> byte offset
      @in_objstm = {}      # object number -> [stream object number, index]
      @seen_xref = {}
    end

    def self.load(data)
      doc = Document.new
      doc.read(data)
      doc
    end

    def read(data)
      @data = data
      head = data.byteslice(0, data.bytesize < 1024 ? data.bytesize : 1024)
      at = Bytes.index(head, "%PDF-", 0)
      @version = data.byteslice(at + 5, 3) if at >= 0
      scan_declarations
      read_xref_chain
      load_objects
      @trailer.each { |_, v| nil }
      @encrypted = true if @trailer.key?("Encrypt")
    end

    # Every `N G obj` the file declares, newest last. Used both to recover
    # objects the xref does not point at and to tell a missing object from an
    # unreadable one.
    def scan_declarations
      data = @data
      n = data.bytesize
      pos = 0
      while true
        at = Bytes.index(data, "obj", pos)
        break if at < 0
        pos = at + 3
        nxt = at + 3
        next if nxt < n && Lex.regular?(data.getbyte(nxt))
        i = at
        i -= 1 while i > 0 && Lex.whitespace?(data.getbyte(i - 1))
        next if i == at
        gen_end = i
        i -= 1 while i > 0 && Lex.digit?(data.getbyte(i - 1))
        next if i == gen_end
        gen_start = i
        i -= 1 while i > 0 && Lex.whitespace?(data.getbyte(i - 1))
        next if i == gen_start
        num_end = i
        i -= 1 while i > 0 && Lex.digit?(data.getbyte(i - 1))
        next if i == num_end
        next if i > 0 && Lex.regular?(data.getbyte(i - 1))
        num = data.byteslice(i, num_end - i).to_i
        @declared[num] = i
      end
    end

    def read_xref_chain
      start = find_startxref
      queue = []
      queue << start if start >= 0
      while !queue.empty?
        at = queue.shift
        next if at < 0 || at >= @data.bytesize
        next if @seen_xref.key?(at)
        @seen_xref[at] = true
        more = read_xref_section(at)
        more.each { |m| queue << m }
      end
      # A file whose xref could not be read at all still has the scan.
      recover_trailer if @trailer.empty? || !@trailer.key?("Root")
    end

    def find_startxref
      tail_len = 2048
      tail_len = @data.bytesize if @data.bytesize < tail_len
      tail = @data.byteslice(@data.bytesize - tail_len, tail_len)
      at = Bytes.rindex(tail, "startxref", -1)
      return -1 if at < 0
      p = Parser.new(tail)
      p.pos = at + 9
      p.skip_space
      word = p.read_regular
      return -1 unless Numbers.integer?(word)
      word.to_i
    end

    # Returns the offsets of further sections to read (/Prev, /XRefStm).
    def read_xref_section(at)
      more = []
      p = Parser.new(@data)
      p.pos = at
      if p.peek_keyword("xref")
        p.pos = p.pos + 4
        read_xref_table(p, more)
      else
        read_xref_stream(at, more)
      end
      more
    end

    def read_xref_table(p, more)
      while true
        p.skip_space
        break if p.eof?
        if p.peek_keyword("trailer")
          p.pos = p.pos + 7
          t = p.parse
          d = t.as_dict
          if d
            d.each { |k, v| @trailer[k] = v unless @trailer.key?(k) }
            prev = d["Prev"]
            more << prev.num if prev && prev.int?
            stm = d["XRefStm"]
            more << stm.num if stm && stm.int?
          end
          break
        end
        word = p.read_regular
        break unless Numbers.integer?(word)
        first = word.to_i
        p.skip_space
        word2 = p.read_regular
        break unless Numbers.integer?(word2)
        count = word2.to_i
        i = 0
        while i < count
          p.skip_space
          off = p.read_regular
          p.skip_space
          _gen = p.read_regular
          p.skip_space
          kind = p.read_regular
          break unless Numbers.integer?(off)
          num = first + i
          if kind == "n" && !@offsets.key?(num) && !@in_objstm.key?(num)
            @offsets[num] = off.to_i
          end
          i += 1
        end
      end
    end

    def read_xref_stream(at, more)
      p = Parser.new(@data)
      p.pos = at
      p.skip_space
      # `N G obj` then the stream.
      word = p.read_regular
      return unless Numbers.integer?(word)
      p.skip_space
      p.read_regular
      return unless p.take_keyword("obj")
      obj = p.parse
      return unless obj.stream?
      d = obj.dict
      return unless d
      d.each { |k, v| @trailer[k] = v unless @trailer.key?(k) }
      prev = d["Prev"]
      more << prev.num if prev && prev.int?
      w = d["W"]
      return unless w && w.array?
      widths = []
      w.items.each { |o| widths << o.to_i }
      return if widths.length < 3
      # A field wider than 8 bytes cannot be read into an integer, and is a
      # damaged /W rather than a cross-reference stream worth following.
      widths.each { |width| return if width < 0 || width > 8 }
      content = nil
      begin
        content = decode_stream_obj(obj, 256 * 1024 * 1024)
      rescue StandardError
        return
      end
      return if content.nil?
      size = d["Size"]
      total = size && size.int? ? size.num : 0
      ranges = []
      index = d["Index"]
      if index && index.array? && index.items.length >= 2
        i = 0
        while i + 1 < index.items.length
          ranges << index.items[i].to_i
          ranges << index.items[i + 1].to_i
          i += 2
        end
      else
        ranges << 0
        ranges << total
      end
      row = widths[0] + widths[1] + widths[2]
      return if row <= 0
      pos = 0
      ri = 0
      while ri + 1 < ranges.length
        first = ranges[ri]
        count = ranges[ri + 1]
        ri += 2
        k = 0
        while k < count && pos + row <= content.bytesize
          f1 = widths[0] == 0 ? 1 : read_be(content, pos, widths[0])
          f2 = read_be(content, pos + widths[0], widths[1])
          f3 = read_be(content, pos + widths[0] + widths[1], widths[2])
          pos += row
          num = first + k
          k += 1
          next if @offsets.key?(num) || @in_objstm.key?(num)
          if f1 == 1
            @offsets[num] = f2
          elsif f1 == 2
            @in_objstm[num] = [f2, f3]
          end
        end
      end
    end

    def read_be(data, pos, width)
      v = 0
      i = 0
      while i < width
        v = (v << 8) | data.getbyte(pos + i)
        i += 1
      end
      v
    end

    def recover_trailer
      at = Bytes.rindex(@data, "trailer", -1)
      while at >= 0
        p = Parser.new(@data)
        p.pos = at + 7
        t = p.parse
        d = t.as_dict
        if d
          d.each { |k, v| @trailer[k] = v unless @trailer.key?(k) }
        end
        break if @trailer.key?("Root")
        at = at > 0 ? Bytes.rindex(@data, "trailer", at - 1) : -1
      end
      return if @trailer.key?("Root")
      # Still no /Root: find a catalog among the declared objects.
      @declared.each do |num, off|
        next if @trailer.key?("Root")
        o = parse_at(off, num)
        next if o.nil?
        d = o.as_dict
        next if d.nil?
        ty = d["Type"]
        @trailer["Root"] = Obj.ref(num, 0) if ty && ty.name? && ty.str == "Catalog"
      end
    end

    def parse_at(offset, expect)
      return nil if offset < 0 || offset >= @data.bytesize
      p = Parser.new(@data)
      p.pos = offset
      p.skip_space
      word = p.read_regular
      return nil unless Numbers.integer?(word)
      num = word.to_i
      p.skip_space
      p.read_regular
      return nil unless p.take_keyword("obj")
      return nil if expect >= 0 && num != expect
      p.parse
    end

    def load_objects
      # Objects the xref points straight at.
      @repaired_xref = true if @offsets.empty? && @in_objstm.empty?
      @offsets.each do |num, off|
        o = parse_at(off, num)
        # A wrong offset is common; fall back to the scan.
        if o.nil? && @declared.key?(num)
          o = parse_at(@declared[num], num)
          @repaired_objects = @repaired_objects + 1 if o
        end
        @objects[num] = o if o
      end
      # Objects declared in the file the xref never mentions.
      @declared.each do |num, off|
        next if @objects.key?(num) || @in_objstm.key?(num)
        o = parse_at(off, num)
        @objects[num] = o if o
      end
      load_object_streams
      @objects.each { |num, _| @max_id = num if num > @max_id }
      @declared.each { |num, _| @max_id = num if num > @max_id }
    end

    def load_object_streams
      wanted = {}
      @in_objstm.each do |num, loc|
        stm = loc[0]
        list = wanted[stm]
        list = [] if list.nil?
        list << num
        wanted[stm] = list
      end
      # Files whose xref is broken still need their object streams read, so
      # every /Type /ObjStm found by the scan is expanded as well.
      @objects.each do |num, o|
        next unless o.stream?
        d = o.dict
        next if d.nil?
        ty = d["Type"]
        next unless ty && ty.name? && ty.str == "ObjStm"
        wanted[num] = [] unless wanted.key?(num)
      end
      wanted.each do |stm_num, _|
        expand_object_stream(stm_num)
      end
    end

    def expand_object_stream(stm_num)
      stm = @objects[stm_num]
      return if stm.nil? || !stm.stream?
      d = stm.dict
      return if d.nil?
      content = nil
      begin
        content = decode_stream_obj(stm, 256 * 1024 * 1024)
      rescue StandardError
        return
      end
      return if content.nil?
      n = d["N"]
      first = d["First"]
      return if n.nil? || first.nil?
      count = n.to_i
      base = first.to_i
      header = Parser.new(content)
      nums = []
      offs = []
      i = 0
      while i < count
        header.skip_space
        a = header.read_regular
        header.skip_space
        b = header.read_regular
        break unless Numbers.integer?(a) && Numbers.integer?(b)
        nums << a.to_i
        offs << b.to_i
        i += 1
      end
      i = 0
      while i < nums.length
        num = nums[i]
        # A top-level definition of the same object wins only when the xref
        # says so; the xref map is what decides here.
        if @in_objstm.key?(num) || !@objects.key?(num)
          p = Parser.new(content)
          p.pos = base + offs[i]
          if p.pos < content.bytesize
            @objects[num] = p.parse
          end
        end
        i += 1
      end
    end

    # ---- object access ------------------------------------------------

    def get(num)
      @objects[num]
    end

    def resolve(obj)
      return Obj.null if obj.nil?
      depth = 0
      o = obj
      while o.ref? && depth < 64
        nxt = @objects[o.num]
        return Obj.null if nxt.nil?
        o = nxt
        depth += 1
      end
      o
    end

    # Dictionary lookup that follows references and reads null as missing.
    def dget(dict, key)
      return nil if dict.nil?
      v = dict[key]
      return nil if v.nil?
      r = resolve(v)
      return nil if r.null?
      r
    end

    def dget_raw(dict, key)
      return nil if dict.nil?
      dict[key]
    end

    def dget_number(dict, key)
      v = dget(dict, key)
      return nil if v.nil? || !v.number?
      v.to_f
    end

    def dget_int(dict, key)
      v = dget(dict, key)
      return nil if v.nil? || !v.number?
      v.to_i
    end

    def dget_bool(dict, key)
      v = dget(dict, key)
      return nil if v.nil? || !v.bool?
      v.num != 0
    end

    def dget_name(dict, key)
      v = dget(dict, key)
      return nil if v.nil? || !v.name?
      v.str
    end

    def dget_dict(dict, key)
      v = dget(dict, key)
      return nil if v.nil?
      v.as_dict
    end

    # A numeric array, or nil when any element is not a number.
    def numbers(obj)
      o = resolve(obj)
      return nil unless o.array?
      out = []
      ok = true
      o.items.each do |it|
        r = resolve(it)
        if r.number?
          out << r.to_f
        else
          ok = false
        end
      end
      return nil unless ok
      out
    end

    def dget_numbers(dict, key)
      v = dget(dict, key)
      return nil if v.nil?
      numbers(v)
    end

    def add(obj)
      @max_id += 1
      @objects[@max_id] = obj
      @max_id
    end

    # ---- streams ------------------------------------------------------

    def filters(dict)
      out = []
      f = dget(dict, "Filter")
      return out if f.nil?
      if f.name?
        out << Filters.full_name(f.str)
      elsif f.array?
        f.items.each do |it|
          r = resolve(it)
          out << Filters.full_name(r.str) if r.name?
        end
      end
      out
    end

    def decode_parms(dict, count)
      out = []
      p = dget(dict, "DecodeParms")
      p = dget(dict, "DP") if p.nil?
      if p
        if p.array?
          p.items.each do |it|
            r = resolve(it)
            out << r.as_dict
          end
        else
          out << p.as_dict
        end
      end
      out << nil while out.length < count
      out
    end

    # Decodes a stream's bytes, applying every filter but the image ones.
    def decode_stream_obj(stream, limit)
      dict = stream.dict
      names = filters(dict)
      data = stream.raw
      if names.empty?
        raise Filters::LimitError, "a stream is larger than #{limit} bytes" if data.bytesize > limit
        return data
      end
      parms = decode_parms(dict, names.length)
      i = 0
      while i < names.length
        name = names[i]
        parm = parms[i]
        i += 1
        if Filters.image_filter?(name)
          # Left encoded; the image code handles these.
          return data
        end
        case name
        when "FlateDecode"
          data = Filters.inflate(data)
        when "LZWDecode"
          early = 1
          if parm
            e = dget_int(parm, "EarlyChange")
            early = e if e
          end
          data = Filters.lzw(data, early != 0)
        when "ASCIIHexDecode"
          data = Filters.ascii_hex(data)
        when "ASCII85Decode"
          data = Filters.ascii85(data)
        when "RunLengthDecode"
          data = Filters.run_length(data)
        when "Crypt"
          nil
        else
          raise Filters::DecodeError, "unsupported filter #{name}"
        end
        if parm
          pred = dget_int(parm, "Predictor")
          if pred && pred > 1
            colors = dget_int(parm, "Colors") || 1
            bpc = dget_int(parm, "BitsPerComponent") || 8
            columns = dget_int(parm, "Columns") || 1
            data = Filters.unpredict(data, pred, colors, bpc, columns)
          end
        end
        if data.bytesize > limit
          raise Filters::LimitError, "a stream decompresses to more than #{limit} bytes"
        end
      end
      data
    end

    # ---- page tree ----------------------------------------------------

    def catalog
      root = @trailer["Root"]
      return nil if root.nil?
      resolve(root).as_dict
    end

    def pages
      out = []
      cat = catalog
      return out if cat.nil?
      root = dget_raw(cat, "Pages")
      return out if root.nil?
      start = root.ref? ? root.num : -1
      if start < 0
        d = resolve(root).as_dict
        return out if d.nil?
        walk_pages_dict(d, out, {}, 0)
        return out
      end
      walk_pages(start, out, {}, 0)
      out
    end

    def walk_pages(num, out, seen, depth)
      return if depth > 64 || seen.key?(num)
      seen[num] = true
      o = @objects[num]
      return if o.nil?
      d = o.as_dict
      return if d.nil?
      ty = dget_name(d, "Type")
      kids = dget(d, "Kids")
      if kids && kids.array? && ty != "Page"
        kids.items.each do |k|
          if k.ref?
            walk_pages(k.num, out, seen, depth + 1)
          end
        end
      else
        out << num
      end
    end

    def walk_pages_dict(d, out, seen, depth)
      kids = dget(d, "Kids")
      return if kids.nil? || !kids.array?
      kids.items.each do |k|
        walk_pages(k.num, out, seen, depth + 1) if k.ref?
      end
    end

    # The content stream object numbers of a page.
    def page_contents(page_num)
      out = []
      o = @objects[page_num]
      return out if o.nil?
      d = o.as_dict
      return out if d.nil?
      c = dget_raw(d, "Contents")
      return out if c.nil?
      if c.ref?
        target = resolve(c)
        if target.array?
          target.items.each { |it| out << it.num if it.ref? }
        else
          out << c.num
        end
      elsif c.array?
        c.items.each { |it| out << it.num if it.ref? }
      end
      out
    end
  end
end
