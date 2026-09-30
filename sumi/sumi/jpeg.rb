# A baseline JPEG decoder, for /DCTDecode images.
#
# Covers SOF0 and SOF1 (baseline and extended sequential, 8-bit), any
# subsampling, restart intervals, and the Adobe APP14 colour transform marker.
# Progressive JPEG (SOF2) and 12-bit samples are reported as unsupported, the
# way the Rust version reports the formats its decoder declines.

module Sumi
  ZIGZAG = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
  ]

  class HuffTable
    FAST_BITS = 9

    attr_accessor :fast, :symbols, :maxcode, :delta

    def initialize
      @fast = []
      @symbols = []
      @maxcode = []
      @delta = []
    end

    # Builds the canonical Huffman tables plus a FAST_BITS lookup.
    def build(counts, values)
      @symbols = values
      @fast = []
      i = 0
      size = 1 << FAST_BITS
      while i < size
        @fast << -1
        i += 1
      end
      @maxcode = []
      @delta = []
      code = 0
      k = 0
      len = 1
      while len <= 16
        @delta << (k - code)
        first_code = code
        count = counts[len - 1]
        j = 0
        while j < count
          if len <= FAST_BITS
            lo = code << (FAST_BITS - len)
            hi = lo + (1 << (FAST_BITS - len))
            f = lo
            while f < hi
              @fast[f] = (len << 16) | k
              f += 1
            end
          end
          code += 1
          k += 1
          j += 1
        end
        # Codes of this length end below `code`; shift for the next length.
        @maxcode << (count == 0 ? -1 : code - 1)
        code = code << 1
        len += 1
      end
      self
    end
  end

  class Component
    attr_accessor :id, :h, :v, :tq, :td, :ta, :dc_pred
    attr_accessor :plane, :plane_w, :plane_h, :blocks_w, :blocks_h
    # Progressive scans accumulate coefficients here, 64 per block in natural
    # order, and the inverse DCT runs once every scan has been read.
    attr_accessor :coeffs

    def initialize
      @id = 0
      @h = 1
      @v = 1
      @tq = 0
      @td = 0
      @ta = 0
      @dc_pred = 0
      @plane = nil
      @coeffs = nil
      @plane_w = 0
      @plane_h = 0
      @blocks_w = 0
      @blocks_h = 0
    end
  end

  class JpegImage
    attr_accessor :width, :height, :components, :pixels, :adobe

    def initialize
      @width = 0
      @height = 0
      @components = 0
      @pixels = nil
      @adobe = -1
    end
  end

  class Jpeg
    def initialize(data)
      @data = data
      @len = data.bytesize
      # Quantization tables in natural order, and the Huffman tables, keyed by
      # their table number. A hash keeps each slot's type known.
      @quant = {}
      @dc = {}
      @ac = {}
      @comps = []
      @width = 0
      @height = 0
      @restart_interval = 0
      @adobe_transform = -1
      @progressive = false
      @scans = 0
      @scan_at = -1
      @ss = 0
      @se = 63
      @ah = 0
      @al = 0
      @eob_run = 0
      @scan_comps = []
      @hmax = 1
      @vmax = 1
      @bitbuf = 0
      @bitcnt = 0
      @pos = 0
      @marker_hit = false
      @block = []
      k = 0
      while k < 64
        @block << 0
        k += 1
      end
    end

    def self.size_of(data)
      j = Jpeg.new(data)
      j.read_headers
      [j.width_of, j.height_of, j.ncomp_of]
    end

    def width_of = @width
    def height_of = @height
    def ncomp_of = @comps.length
    def adobe_of = @adobe_transform

    def u16(at)
      (@data.getbyte(at) << 8) | @data.getbyte(at + 1)
    end

    # Walks the marker segments. Baseline files have one scan; progressive ones
    # have several, and each is decoded as it is met.
    def read_headers
      raise Filters::DecodeError, "not a JPEG" if @len < 4
      pos = 0
      pos = 2 if @data.getbyte(0) == 0xff && @data.getbyte(1) == 0xd8
      while pos + 1 < @len
        unless @data.getbyte(pos) == 0xff
          pos += 1
          next
        end
        marker = @data.getbyte(pos + 1)
        if marker == 0xff
          pos += 1
          next
        end
        if marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)
          pos += 2
          next
        end
        break if marker == 0xd9
        raise Filters::DecodeError, "truncated JPEG" if pos + 4 > @len
        length = u16(pos + 2)
        seg = pos + 4
        seg_len = length - 2
        raise Filters::DecodeError, "truncated JPEG segment" if seg + seg_len > @len
        case marker
        when 0xc0, 0xc1
          @progressive = false
          read_sof(seg, seg_len)
        when 0xc2
          @progressive = true
          read_sof(seg, seg_len)
        when 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf
          raise Filters::UnsupportedError, "unsupported JPEG encoding"
        when 0xc4
          read_dht(seg, seg_len)
        when 0xdb
          read_dqt(seg, seg_len)
        when 0xdd
          @restart_interval = u16(seg)
        when 0xee
          read_adobe(seg, seg_len)
        when 0xda
          @scan_at = pos
          read_scan_header
          allocate_planes if @comps[0].plane.nil? && @comps[0].coeffs.nil?
          decode_scan
          @scans += 1
          pos = next_marker(@pos)
          next
        end
        pos = seg + seg_len
      end
    end

    # The offset of the next marker at or after `from`, skipping the padding
    # and restart markers an entropy-coded segment ends with.
    def next_marker(from)
      i = from
      while i + 1 < @len
        if @data.getbyte(i) == 0xff
          m = @data.getbyte(i + 1)
          return i unless m == 0xff || m == 0x00 || (m >= 0xd0 && m <= 0xd7)
          i += m == 0xff ? 1 : 2
          next
        end
        i += 1
      end
      @len
    end

    def read_sof(seg, seg_len)
      raise Filters::DecodeError, "malformed JPEG frame" if seg_len < 6
      precision = @data.getbyte(seg)
      raise Filters::UnsupportedError, "#{precision}-bit JPEG image" unless precision == 8
      @height = u16(seg + 1)
      @width = u16(seg + 3)
      n = @data.getbyte(seg + 5)
      raise Filters::DecodeError, "JPEG without components" if n < 1 || n > 4
      @comps = []
      i = 0
      while i < n
        at = seg + 6 + i * 3
        c = Component.new
        c.id = @data.getbyte(at)
        hv = @data.getbyte(at + 1)
        c.h = (hv >> 4) & 0xf
        c.v = hv & 0xf
        c.h = 1 if c.h < 1
        c.v = 1 if c.v < 1
        c.tq = @data.getbyte(at + 2) & 3
        @comps << c
        i += 1
      end
    end

    def read_dqt(seg, seg_len)
      at = seg
      stop = seg + seg_len
      while at < stop
        pq = (@data.getbyte(at) >> 4) & 0xf
        tq = @data.getbyte(at) & 3
        at += 1
        table = []
        k = 0
        while k < 64
          table << 0
          k += 1
        end
        k = 0
        while k < 64
          if pq == 1
            table[ZIGZAG[k]] = u16(at)
            at += 2
          else
            table[ZIGZAG[k]] = @data.getbyte(at)
            at += 1
          end
          k += 1
        end
        @quant[tq] = table
      end
    end

    def read_dht(seg, seg_len)
      at = seg
      stop = seg + seg_len
      while at + 17 <= stop
        tc = (@data.getbyte(at) >> 4) & 0xf
        th = @data.getbyte(at) & 3
        at += 1
        counts = []
        total = 0
        i = 0
        while i < 16
          c = @data.getbyte(at + i)
          counts << c
          total += c
          i += 1
        end
        at += 16
        break if at + total > stop
        values = []
        i = 0
        while i < total
          values << @data.getbyte(at + i)
          i += 1
        end
        at += total
        table = HuffTable.new.build(counts, values)
        if tc == 0
          @dc[th] = table
        else
          @ac[th] = table
        end
      end
    end

    def read_adobe(seg, seg_len)
      return if seg_len < 12
      return unless @data.byteslice(seg, 5) == "Adobe"
      @adobe_transform = @data.getbyte(seg + seg_len - 1)
    end

    # ---- entropy-coded data -------------------------------------------

    def fill_bits
      while @bitcnt <= 24
        if @marker_hit
          @bitbuf = (@bitbuf << 8) & 0xffffffff
          @bitcnt += 8
          next
        end
        b = @pos < @len ? @data.getbyte(@pos) : 0
        @pos += 1
        if b == 0xff
          nxt = @pos < @len ? @data.getbyte(@pos) : 0xd9
          if nxt == 0x00
            @pos += 1
          elsif nxt >= 0xd0 && nxt <= 0xd7
            # A restart marker is consumed by reset_stream.
            @pos -= 1
            @marker_hit = true
            b = 0
          else
            @pos -= 1
            @marker_hit = true
            b = 0
          end
        end
        @bitbuf = ((@bitbuf << 8) | b) & 0xffffffff
        @bitcnt += 8
      end
    end

    def receive(n)
      return 0 if n == 0
      fill_bits if @bitcnt < n
      v = (@bitbuf >> (@bitcnt - n)) & ((1 << n) - 1)
      @bitcnt -= n
      v
    end

    # Sign-extends an n-bit JPEG magnitude.
    def extend_value(v, n)
      return 0 if n == 0
      v < (1 << (n - 1)) ? v - (1 << n) + 1 : v
    end

    def decode_huff(table)
      fill_bits if @bitcnt < 16
      peek = (@bitbuf >> (@bitcnt - HuffTable::FAST_BITS)) & ((1 << HuffTable::FAST_BITS) - 1)
      hit = table.fast[peek]
      if hit >= 0
        len = hit >> 16
        @bitcnt -= len
        return table.symbols[hit & 0xffff]
      end
      # A code longer than FAST_BITS: walk the lengths.
      code = 0
      len = 1
      while len <= 16
        code = (code << 1) | receive(1)
        mx = table.maxcode[len - 1]
        if mx >= 0 && code <= mx
          idx = code + table.delta[len - 1]
          return 0 if idx < 0 || idx >= table.symbols.length
          return table.symbols[idx]
        end
        len += 1
      end
      0
    end

    def reset_stream
      @bitbuf = 0
      @bitcnt = 0
      @marker_hit = false
      # Skip a restart marker if that is what stopped the bit reader.
      while @pos + 1 < @len
        break unless @data.getbyte(@pos) == 0xff
        m = @data.getbyte(@pos + 1)
        if m >= 0xd0 && m <= 0xd7
          @pos += 2
          next
        end
        break
      end
      @comps.each { |c| c.dc_pred = 0 }
      @eob_run = 0
    end

    def decode
      read_headers
      raise Filters::DecodeError, "JPEG without a scan" if @scans == 0
      raise Filters::DecodeError, "JPEG without dimensions" if @width < 1 || @height < 1
      finish_progressive if @progressive
      build_pixels
    end

    def read_scan_header
      seg = @scan_at + 4
      n = @data.getbyte(seg)
      @scan_comps = []
      i = 0
      while i < n
        cid = @data.getbyte(seg + 1 + i * 2)
        tt = @data.getbyte(seg + 2 + i * 2)
        @comps.each do |c|
          if c.id == cid
            c.td = (tt >> 4) & 3
            c.ta = tt & 3
            @scan_comps << c
          end
        end
        i += 1
      end
      raise Filters::DecodeError, "JPEG scan without components" if @scan_comps.empty?
      at = seg + 1 + n * 2
      @ss = @data.getbyte(at)
      @se = @data.getbyte(at + 1)
      ah_al = @data.getbyte(at + 2)
      @ah = (ah_al >> 4) & 0xf
      @al = ah_al & 0xf
      unless @progressive
        @ss = 0
        @se = 63
        @ah = 0
        @al = 0
      end
      @se = 63 if @se > 63
      raise Filters::DecodeError, "malformed JPEG scan" if @ss > @se
      @eob_run = 0
      @bitbuf = 0
      @bitcnt = 0
      @marker_hit = false
      @comps.each { |c| c.dc_pred = 0 }
      length = u16(@scan_at + 2)
      @pos = @scan_at + 2 + length
    end

    def allocate_planes
      hmax = 1
      vmax = 1
      @comps.each do |c|
        hmax = c.h if c.h > hmax
        vmax = c.v if c.v > vmax
      end
      @hmax = hmax
      @vmax = vmax
      @mcu_w = hmax * 8
      @mcu_h = vmax * 8
      @mcus_x = (@width + @mcu_w - 1) / @mcu_w
      @mcus_y = (@height + @mcu_h - 1) / @mcu_h
      @comps.each do |c|
        c.blocks_w = @mcus_x * c.h
        c.blocks_h = @mcus_y * c.v
        c.plane_w = c.blocks_w * 8
        c.plane_h = c.blocks_h * 8
        plane = []
        total = c.plane_w * c.plane_h
        i = 0
        while i < total
          plane << 0
          i += 1
        end
        c.plane = plane
        next unless @progressive
        coeffs = []
        total = c.blocks_w * c.blocks_h * 64
        i = 0
        while i < total
          coeffs << 0
          i += 1
        end
        c.coeffs = coeffs
      end
    end

    def decode_scan
      single = @scan_comps.length == 1
      if single
        c = @scan_comps[0]
        # A non-interleaved scan walks the component's own blocks.
        bw = (@width * c.h + @mcu_w - 1) / @mcu_w
        bh = (@height * c.v + @mcu_h - 1) / @mcu_h
        bw = 1 if bw < 1
        bh = 1 if bh < 1
        todo = @restart_interval
        by = 0
        while by < bh
          bx = 0
          while bx < bw
            @progressive ? decode_block_progressive(c, bx, by) : decode_block(c, bx, by)
            bx += 1
            if @restart_interval > 0
              todo -= 1
              if todo == 0
                reset_stream
                todo = @restart_interval
              end
            end
          end
          by += 1
        end
        return
      end

      todo = @restart_interval
      my = 0
      while my < @mcus_y
        mx = 0
        while mx < @mcus_x
          @scan_comps.each do |c|
            vy = 0
            while vy < c.v
              vx = 0
              while vx < c.h
                bx = mx * c.h + vx
                by = my * c.v + vy
                @progressive ? decode_block_progressive(c, bx, by) : decode_block(c, bx, by)
                vx += 1
              end
              vy += 1
            end
          end
          mx += 1
          if @restart_interval > 0
            todo -= 1
            if todo == 0
              reset_stream
              todo = @restart_interval
            end
          end
        end
        my += 1
      end
    end

    # ---- progressive scans ---------------------------------------------

    def decode_block_progressive(c, bx, by)
      return if bx >= c.blocks_w || by >= c.blocks_h
      base = (by * c.blocks_w + bx) * 64
      if @ss == 0
        decode_dc_progressive(c, base)
      else
        decode_ac_progressive(c, base)
      end
    end

    def decode_dc_progressive(c, base)
      coeffs = c.coeffs
      if @ah == 0
        dct = @dc[c.td]
        return if dct.nil?
        t = decode_huff(dct)
        raise Filters::DecodeError, "bad Huffman value in JPEG" if t > 16
        diff = t == 0 ? 0 : extend_value(receive(t), t)
        c.dc_pred += diff
        coeffs[base] = c.dc_pred << @al
      elsif receive(1) != 0
        coeffs[base] = coeffs[base] + (1 << @al)
      end
    end

    def decode_ac_progressive(c, base)
      coeffs = c.coeffs
      act = @ac[c.ta]
      return if act.nil?
      if @ah == 0
        # First pass over this band: the coefficients arrive as they are.
        if @eob_run > 0
          @eob_run -= 1
          return
        end
        k = @ss
        while k <= @se
          rs = decode_huff(act)
          s_bits = rs & 15
          r = rs >> 4
          if s_bits == 0
            if r < 15
              @eob_run = (1 << r) - 1
              @eob_run += receive(r) if r > 0
              break
            end
            k += 16
            next
          end
          k += r
          break if k > 63
          coeffs[base + ZIGZAG[k]] = extend_value(receive(s_bits), s_bits) << @al
          k += 1
        end
        return
      end

      # Refinement pass: one bit per already-nonzero coefficient, and newly
      # nonzero ones arrive with their sign.
      bit = 1 << @al
      if @eob_run > 0
        @eob_run -= 1
        k = @ss
        while k <= @se
          at = base + ZIGZAG[k]
          refine(coeffs, at, bit) if coeffs[at] != 0
          k += 1
        end
        return
      end

      k = @ss
      while k <= @se
        rs = decode_huff(act)
        s_bits = rs & 15
        r = rs >> 4
        value = 0
        if s_bits == 0
          if r < 15
            @eob_run = (1 << r) - 1
            @eob_run += receive(r) if r > 0
            r = 64
          end
        else
          raise Filters::DecodeError, "bad progressive JPEG scan" if s_bits != 1
          value = receive(1) != 0 ? bit : -bit
        end
        while k <= @se
          at = base + ZIGZAG[k]
          k += 1
          if coeffs[at] != 0
            refine(coeffs, at, bit)
          else
            if r == 0
              coeffs[at] = value if value != 0
              break
            end
            r -= 1
          end
        end
      end
    end

    # Adds the refinement bit to a coefficient that already has a value.
    def refine(coeffs, at, bit)
      return if receive(1) == 0
      v = coeffs[at]
      return if (v & bit) != 0
      coeffs[at] = v > 0 ? v + bit : v - bit
    end

    # Dequantizes every block and runs the inverse DCT, once all scans are in.
    def finish_progressive
      @comps.each do |c|
        coeffs = c.coeffs
        next if coeffs.nil?
        quant = @quant[c.tq]
        quant = DEFAULT_QUANT if quant.nil?
        blk = @block
        by = 0
        while by < c.blocks_h
          bx = 0
          while bx < c.blocks_w
            base = (by * c.blocks_w + bx) * 64
            i = 0
            while i < 64
              blk[i] = coeffs[base + i] * quant[i]
              i += 1
            end
            idct_block(blk, c.plane, c.plane_w, bx * 8, by * 8)
            bx += 1
          end
          by += 1
        end
        c.coeffs = nil
      end
    end

    def decode_block(c, bx, by)
      blk = @block
      i = 0
      while i < 64
        blk[i] = 0
        i += 1
      end
      quant = @quant[c.tq]
      quant = DEFAULT_QUANT if quant.nil?
      dct = @dc[c.td]
      act = @ac[c.ta]
      return if dct.nil? || act.nil?

      t = decode_huff(dct)
      # A damaged table can hand back any byte; a DC magnitude category is at
      # most 16 bits, and anything past that is a broken stream, not a shift.
      raise Filters::DecodeError, "bad Huffman value in JPEG" if t > 16
      diff = t == 0 ? 0 : extend_value(receive(t), t)
      c.dc_pred = c.dc_pred + diff
      blk[0] = c.dc_pred * quant[0]

      k = 1
      while k < 64
        rs = decode_huff(act)
        s = rs & 15
        r = rs >> 4
        if s == 0
          break if r != 15
          k += 16
          next
        end
        k += r
        break if k > 63
        zz = ZIGZAG[k]
        blk[zz] = extend_value(receive(s), s) * quant[zz]
        k += 1
      end

      idct_block(blk, c.plane, c.plane_w, bx * 8, by * 8)
    end

    # ---- inverse DCT ---------------------------------------------------

    # The integer IDCT of the JPEG reference implementation, as used by
    # stb_image: 1-D passes over columns then rows, 8-bit clamped output.
    def idct_block(blk, plane, stride, ox, oy)
      tmp = @tmp
      if tmp.nil?
        tmp = []
        i = 0
        while i < 64
          tmp << 0
          i += 1
        end
        @tmp = tmp
      end

      i = 0
      while i < 8
        if blk[i + 8] == 0 && blk[i + 16] == 0 && blk[i + 24] == 0 &&
           blk[i + 32] == 0 && blk[i + 40] == 0 && blk[i + 48] == 0 && blk[i + 56] == 0
          dc = blk[i] * 4
          tmp[i] = dc
          tmp[i + 8] = dc
          tmp[i + 16] = dc
          tmp[i + 24] = dc
          tmp[i + 32] = dc
          tmp[i + 40] = dc
          tmp[i + 48] = dc
          tmp[i + 56] = dc
          i += 1
          next
        end
        s0 = blk[i]
        s1 = blk[i + 8]
        s2 = blk[i + 16]
        s3 = blk[i + 24]
        s4 = blk[i + 32]
        s5 = blk[i + 40]
        s6 = blk[i + 48]
        s7 = blk[i + 56]

        p2 = s2
        p3 = s6
        p1 = (p2 + p3) * 2217
        t2 = p1 + p3 * -7567
        t3 = p1 + p2 * 3135
        p2 = s0
        p3 = s4
        t0 = (p2 + p3) * 4096
        t1 = (p2 - p3) * 4096
        x0 = t0 + t3
        x3 = t0 - t3
        x1 = t1 + t2
        x2 = t1 - t2

        t0 = s7
        t1 = s5
        t2 = s3
        t3 = s1
        p3 = t0 + t2
        p4 = t1 + t3
        p1 = t0 + t3
        p2 = t1 + t2
        p5 = (p3 + p4) * 4816
        t0 = t0 * 1223
        t1 = t1 * 8410
        t2 = t2 * 12586
        t3 = t3 * 6149
        p1 = p5 + p1 * -3685
        p2 = p5 + p2 * -10497
        p3 = p3 * -8034
        p4 = p4 * -1597
        t3 += p1 + p4
        t2 += p2 + p3
        t1 += p2 + p4
        t0 += p1 + p3

        x0 += 512
        x1 += 512
        x2 += 512
        x3 += 512
        tmp[i] = (x0 + t3) >> 10
        tmp[i + 56] = (x0 - t3) >> 10
        tmp[i + 8] = (x1 + t2) >> 10
        tmp[i + 48] = (x1 - t2) >> 10
        tmp[i + 16] = (x2 + t1) >> 10
        tmp[i + 40] = (x2 - t1) >> 10
        tmp[i + 24] = (x3 + t0) >> 10
        tmp[i + 32] = (x3 - t0) >> 10
        i += 1
      end

      row = 0
      while row < 8
        at = row * 8
        s0 = tmp[at]
        s1 = tmp[at + 1]
        s2 = tmp[at + 2]
        s3 = tmp[at + 3]
        s4 = tmp[at + 4]
        s5 = tmp[at + 5]
        s6 = tmp[at + 6]
        s7 = tmp[at + 7]

        p2 = s2
        p3 = s6
        p1 = (p2 + p3) * 2217
        t2 = p1 + p3 * -7567
        t3 = p1 + p2 * 3135
        p2 = s0
        p3 = s4
        t0 = (p2 + p3) * 4096
        t1 = (p2 - p3) * 4096
        x0 = t0 + t3
        x3 = t0 - t3
        x1 = t1 + t2
        x2 = t1 - t2

        t0 = s7
        t1 = s5
        t2 = s3
        t3 = s1
        p3 = t0 + t2
        p4 = t1 + t3
        p1 = t0 + t3
        p2 = t1 + t2
        p5 = (p3 + p4) * 4816
        t0 = t0 * 1223
        t1 = t1 * 8410
        t2 = t2 * 12586
        t3 = t3 * 6149
        p1 = p5 + p1 * -3685
        p2 = p5 + p2 * -10497
        p3 = p3 * -8034
        p4 = p4 * -1597
        t3 += p1 + p4
        t2 += p2 + p3
        t1 += p2 + p4
        t0 += p1 + p3

        # 65536 + (128 << 17) centres the output on 128.
        bias = 65536 + (128 << 17)
        x0 += bias
        x1 += bias
        x2 += bias
        x3 += bias

        base = (oy + row) * stride + ox
        plane[base] = clamp8((x0 + t3) >> 17)
        plane[base + 7] = clamp8((x0 - t3) >> 17)
        plane[base + 1] = clamp8((x1 + t2) >> 17)
        plane[base + 6] = clamp8((x1 - t2) >> 17)
        plane[base + 2] = clamp8((x2 + t1) >> 17)
        plane[base + 5] = clamp8((x2 - t1) >> 17)
        plane[base + 3] = clamp8((x3 + t0) >> 17)
        plane[base + 4] = clamp8((x3 - t0) >> 17)
        row += 1
      end
    end

    def clamp8(v)
      return 0 if v < 0
      return 255 if v > 255
      v
    end

    DEFAULT_QUANT = [
      16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
      14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
      18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
      49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99
    ]

    # ---- assembling the image ------------------------------------------

    def build_pixels
      img = JpegImage.new
      img.width = @width
      img.height = @height
      img.adobe = @adobe_transform
      n = @comps.length
      if n == 1
        img.components = 1
        img.pixels = plane_to_string(@comps[0])
        return img
      end
      if n == 3
        img.components = 3
        img.pixels = ycbcr_to_rgb
        return img
      end
      if n == 4
        # Adobe transform 2 is YCCK; the Rust version declines those, so the
        # port declines them too rather than guessing at the inversion.
        if @adobe_transform == 2
          raise Filters::UnsupportedError, "YCCK (Adobe CMYK) JPEG image"
        end
        img.components = 4
        img.pixels = interleave4
        return img
      end
      raise Filters::UnsupportedError, "#{n}-component JPEG image"
    end

    # For each output column, the index into a component's plane row. The
    # subsampling divisions are done once per image rather than per pixel.
    def column_map(c)
      sx = @hmax / c.h
      map = []
      x = 0
      while x < @width
        px = x / sx
        px = c.plane_w - 1 if px >= c.plane_w
        map << px
        x += 1
      end
      map
    end

    # For each output row, the offset of a component's plane row.
    def row_map(c)
      sy = @vmax / c.v
      map = []
      y = 0
      while y < @height
        py = y / sy
        py = c.plane_h - 1 if py >= c.plane_h
        map << py * c.plane_w
        y += 1
      end
      map
    end

    # A component's samples at full image resolution, as bytes.
    def plane_to_string(c)
      out = String.new
      plane = c.plane
      cols = column_map(c)
      rows = row_map(c)
      width = @width
      y = 0
      while y < @height
        base = rows[y]
        x = 0
        while x < width
          out << plane[base + cols[x]].chr
          x += 1
        end
        y += 1
      end
      out
    end

    def sample(c, x, y)
      sx = @hmax / c.h
      sy = @vmax / c.v
      px = x / sx
      py = y / sy
      px = c.plane_w - 1 if px >= c.plane_w
      py = c.plane_h - 1 if py >= c.plane_h
      c.plane[py * c.plane_w + px]
    end

    def rgb?
      # Component ids R, G and B mean the data was never transformed.
      @comps[0].id == 0x52 && @comps[1].id == 0x47 && @comps[2].id == 0x42
    end

    def ycbcr_to_rgb
      out = String.new
      c0 = @comps[0]
      c1 = @comps[1]
      c2 = @comps[2]
      p0 = c0.plane
      p1 = c1.plane
      p2 = c2.plane
      m0 = column_map(c0)
      m1 = column_map(c1)
      m2 = column_map(c2)
      r0 = row_map(c0)
      r1 = row_map(c1)
      r2 = row_map(c2)
      plain = rgb?
      width = @width
      y = 0
      while y < @height
        b0 = r0[y]
        b1 = r1[y]
        b2 = r2[y]
        x = 0
        while x < width
          a = p0[b0 + m0[x]]
          b = p1[b1 + m1[x]]
          c = p2[b2 + m2[x]]
          if plain
            out << a.chr << b.chr << c.chr
          else
            cb = b - 128
            cr = c - 128
            r = a + ((91881 * cr) >> 16)
            g = a - ((22554 * cb + 46802 * cr) >> 16)
            bl = a + ((116130 * cb) >> 16)
            r = r < 0 ? 0 : (r > 255 ? 255 : r)
            g = g < 0 ? 0 : (g > 255 ? 255 : g)
            bl = bl < 0 ? 0 : (bl > 255 ? 255 : bl)
            out << r.chr << g.chr << bl.chr
          end
          x += 1
        end
        y += 1
      end
      out
    end

    def interleave4
      out = String.new
      c0 = @comps[0]
      c1 = @comps[1]
      c2 = @comps[2]
      c3 = @comps[3]
      p0 = c0.plane
      p1 = c1.plane
      p2 = c2.plane
      p3 = c3.plane
      m0 = column_map(c0)
      m1 = column_map(c1)
      m2 = column_map(c2)
      m3 = column_map(c3)
      r0 = row_map(c0)
      r1 = row_map(c1)
      r2 = row_map(c2)
      r3 = row_map(c3)
      width = @width
      y = 0
      while y < @height
        b0 = r0[y]
        b1 = r1[y]
        b2 = r2[y]
        b3 = r3[y]
        x = 0
        while x < width
          out << p0[b0 + m0[x]].chr
          out << p1[b1 + m1[x]].chr
          out << p2[b2 + m2[x]].chr
          out << p3[b3 + m3[x]].chr
          x += 1
        end
        y += 1
      end
      out
    end
  end
end
