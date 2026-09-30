# Converts image XObjects and inline images.
#
# Indexed images keep their sample data and only get a gray palette. Other
# images are decoded, converted to 8-bit gray (or 1-bit in monochrome mode)
# and re-encoded with Flate.

module Sumi
  class ImageResult
    PALETTE = 0
    PIXELS = 1

    attr_accessor :kind, :hival, :lookup
    attr_accessor :width, :height, :bits, :data, :soft_mask

    def initialize(kind)
      @kind = kind
      @hival = 0
      @lookup = nil
      @width = 0
      @height = 0
      @bits = 8
      @data = nil
      @soft_mask = nil
    end
  end

  module Image
    # Returns an ImageResult, or nil when the image needs no change.
    def self.convert(doc, dict, stream, resources, settings)
      tone = settings.tone
      model = settings.gray_model
      return nil if doc.dget_bool(dict, "ImageMask") == true
      names = doc.filters(dict)
      last = names.empty? ? nil : names[names.length - 1]
      cs = doc.dget_raw(dict, "ColorSpace")
      if cs.nil?
        raise Filters::UnsupportedError, "JPEG 2000 image" if last == "JPXDecode"
        raise Filters::DecodeError, "image without /ColorSpace"
      end
      space = ColorSpace.resolve(doc, cs, resources, settings.max_stream_bytes)
      width = doc.dget_int(dict, "Width")
      raise Filters::DecodeError, "image without /Width" if width.nil? || width <= 0
      height = doc.dget_int(dict, "Height")
      raise Filters::DecodeError, "image without /Height" if height.nil? || height <= 0
      bits = doc.dget_int(dict, "BitsPerComponent")
      bits = 8 if bits.nil?
      unless bits == 1 || bits == 2 || bits == 4 || bits == 8 || bits == 16
        raise Filters::DecodeError, "image with #{bits} bits per component"
      end
      if width * height > settings.max_image_pixels
        raise Filters::UnsupportedError,
              "image of #{width}x#{height} pixels exceeds the size limit"
      end
      decode = doc.dget_numbers(dict, "Decode")
      decode = decode[0, decode.length - (decode.length % 2)] if decode

      if space.kind == ColorSpace::UNSUPPORTED
        raise Filters::UnsupportedError, "image color space #{space.reason}"
      end
      return nil unless space.convertible?
      if space.kind == ColorSpace::GRAY
        default_decode = decode.nil? || (decode.length >= 2 && decode[0] == 0.0 && decode[1] == 1.0)
        return nil if !tone.monochrome? || (bits == 1 && default_decode)
      end
      if space.kind == ColorSpace::INDEXED
        grays = space.palette_grays(model)
        raise Filters::DecodeError, "malformed palette" if grays.nil?
        lookup = String.new
        grays.each { |g| lookup << (tone.apply(g) * 255.0).round.chr }
        result = ImageResult.new(ImageResult::PALETTE)
        result.hival = grays.length - 1
        result.lookup = lookup
        return result
      end

      samples = nil
      if last == "DCTDecode"
        if names.length != 1
          raise Filters::UnsupportedError, "DCTDecode combined with other filters"
        end
        jpeg = decode_jpeg(stream.raw, settings)
        if jpeg.components != space.components
          space = ColorSpace.simple(ColorSpace::GRAY) if jpeg.components == 1
          space = ColorSpace.simple(ColorSpace::RGB) if jpeg.components == 3
          space = ColorSpace.simple(ColorSpace::CMYK) if jpeg.components == 4
        end
        width = jpeg.width
        height = jpeg.height
        bits = 8
        samples = jpeg.pixels
      elsif last == "JPXDecode" || last == "JBIG2Decode" || last == "CCITTFaxDecode"
        raise Filters::UnsupportedError, "#{last} image in #{space.kind_name}"
      else
        samples = doc.decode_stream_obj(stream, settings.max_stream_bytes)
      end

      n = space.components
      if decode.nil? || decode.length < 2 * n
        decode = space.default_decode(bits)
      end
      row_bytes = (width * n * bits + 7) / 8
      needed = row_bytes * height
      samples = samples + ("\0" * (needed - samples.bytesize)) if samples.bytesize < needed

      gray = to_gray8(space, model, bits, decode, width, height, samples, settings)
      soft_mask = nil
      mask = doc.dget(dict, "Mask")
      if mask && mask.array? && !dict.key?("SMask")
        ranges = doc.dget_numbers(dict, "Mask")
        if ranges && ranges.length >= 2 * n
          soft_mask = color_key_mask(ranges, n, bits, width, height, samples)
        end
      end

      result = ImageResult.new(ImageResult::PIXELS)
      result.width = width
      result.height = height
      result.soft_mask = soft_mask
      if tone.monochrome?
        result.bits = 1
        result.data = to_bilevel(gray, width, height, settings)
      else
        result.bits = 8
        result.data = gray
      end
      result
    end

    def self.sample_at(row, base, index, bits)
      return row.getbyte(base + index) if bits == 8
      if bits == 16
        return (row.getbyte(base + 2 * index) << 8) | row.getbyte(base + 2 * index + 1)
      end
      bit = index * bits
      byte = row.getbyte(base + (bit >> 3))
      (byte >> (8 - (bit & 7) - bits)) & ((1 << bits) - 1)
    end

    def self.to_gray8(space, model, bits, decode, width, height, samples, settings)
      n = space.components
      row_bytes = (width * n * bits + 7) / 8
      row_bytes = 1 if row_bytes < 1
      out = String.new

      dd = space.default_decode(bits)
      default_decode = true
      i = 0
      while i < 2 * n
        if i >= decode.length || i >= dd.length || decode[i] != dd[i]
          default_decode = false
          break
        end
        i += 1
      end

      if bits == 8 && default_decode &&
         (space.kind == ColorSpace::GRAY || space.kind == ColorSpace::RGB ||
          space.kind == ColorSpace::CMYK)
        y = 0
        while y < height
          base = y * row_bytes
          if space.kind == ColorSpace::GRAY
            out << samples.byteslice(base, width)
          elsif space.kind == ColorSpace::RGB
            if model == GRAY_LUMA
              x = 0
              while x < width
                at = base + 3 * x
                out << Color.rgb8_to_gray(samples.getbyte(at), samples.getbyte(at + 1),
                                          samples.getbyte(at + 2)).chr
                x += 1
              end
            else
              srgb = settings.tables
              x = 0
              while x < width
                at = base + 3 * x
                out << srgb.gray(samples.getbyte(at), samples.getbyte(at + 1),
                                 samples.getbyte(at + 2)).chr
                x += 1
              end
            end
          else
            x = 0
            while x < width
              at = base + 4 * x
              out << Color.cmyk8_to_gray(samples.getbyte(at), samples.getbyte(at + 1),
                                         samples.getbyte(at + 2), samples.getbyte(at + 3)).chr
              x += 1
            end
          end
          y += 1
        end
        return out
      end

      max = ((1 << bits) - 1).to_f

      if n == 1 && bits <= 8
        lut = String.new
        s = 0
        top = (1 << bits) - 1
        while s <= top
          v = decode[0] + s.to_f * (decode[1] - decode[0]) / max
          g = space.to_gray([v], model)
          lut << ((g.nil? ? 1.0 : g) * 255.0).round.chr
          s += 1
        end
        y = 0
        while y < height
          base = y * row_bytes
          x = 0
          while x < width
            out << lut.byteslice(sample_at(samples, base, x, bits), 1)
            x += 1
          end
          y += 1
        end
        return out
      end

      comps = []
      i = 0
      while i < n
        comps << 0.0
        i += 1
      end
      y = 0
      while y < height
        base = y * row_bytes
        x = 0
        while x < width
          c = 0
          while c < n
            s = sample_at(samples, base, x * n + c, bits)
            comps[c] = decode[2 * c] + s.to_f * (decode[2 * c + 1] - decode[2 * c]) / max
            c += 1
          end
          g = space.to_gray(comps, model)
          out << ((g.nil? ? 1.0 : g) * 255.0).round.chr
          x += 1
        end
        y += 1
      end
      out
    end

    # Packs gray pixels into 1-bit rows (1 = white), thresholding or dithering.
    def self.to_bilevel(gray, width, height, settings)
      tone = settings.tone
      out = String.new

      unless settings.dither
        white = []
        g = 0
        while g < 256
          white << (tone.apply(g.to_f / 255.0) == 1.0 ? 1 : 0)
          g += 1
        end
        y = 0
        while y < height
          base = y * width
          x = 0
          while x < width
            bits = 0
            k = 0
            while k < 8
              px = x + k
              bit = px < width && white[gray.getbyte(base + px)] == 1 ? 1 : 0
              bits = (bits << 1) | bit
              k += 1
            end
            out << bits.chr
            x += 8
          end
          y += 1
        end
        return out
      end

      threshold = tone.threshold * 255.0
      current = []
      nextrow = []
      i = 0
      while i < width + 2
        current << 0.0
        nextrow << 0.0
        i += 1
      end
      y = 0
      while y < height
        base = y * width
        x = 0
        while x < width
          bits = 0
          k = 0
          while k < 8
            px = x + k
            if px < width
              v = gray.getbyte(base + px).to_f + current[px + 1]
              on = v >= threshold
              bits = (bits << 1) | (on ? 1 : 0)
              err = v - (on ? 255.0 : 0.0)
              current[px + 2] = current[px + 2] + err * 7.0 / 16.0
              nextrow[px] = nextrow[px] + err * 3.0 / 16.0
              nextrow[px + 1] = nextrow[px + 1] + err * 5.0 / 16.0
              nextrow[px + 2] = nextrow[px + 2] + err / 16.0
            else
              bits = bits << 1
            end
            k += 1
          end
          out << bits.chr
          x += 8
        end
        swap = current
        current = nextrow
        nextrow = swap
        i = 0
        while i < nextrow.length
          nextrow[i] = 0.0
          i += 1
        end
        y += 1
      end
      out
    end

    def self.color_key_mask(ranges, n, bits, width, height, samples)
      row_bytes = (width * n * bits + 7) / 8
      row_bytes = 1 if row_bytes < 1
      out = String.new
      y = 0
      while y < height
        base = y * row_bytes
        x = 0
        while x < width
          masked = true
          c = 0
          while c < n
            s = sample_at(samples, base, x * n + c, bits).to_f
            if s < ranges[2 * c] || s > ranges[2 * c + 1]
              masked = false
              break
            end
            c += 1
          end
          out << (masked ? 0.chr : 255.chr)
          x += 1
        end
        y += 1
      end
      out
    end

    def self.decode_jpeg(data, settings)
      j = Jpeg.new(data)
      img = j.decode
      if img.width * img.height > settings.max_image_pixels
        raise Filters::UnsupportedError,
              "image of #{img.width}x#{img.height} pixels exceeds the size limit"
      end
      if img.pixels.bytesize < img.width * img.height * img.components
        raise Filters::DecodeError, "truncated JPEG"
      end
      img
    end

    def self.gray_image_dict(width, height, bits)
      d = {}
      d["Type"] = Obj.name("XObject")
      d["Subtype"] = Obj.name("Image")
      d["Width"] = Obj.int(width)
      d["Height"] = Obj.int(height)
      d["ColorSpace"] = Obj.name("DeviceGray")
      d["BitsPerComponent"] = Obj.int(bits)
      d
    end

    # Converts an image XObject in place.
    def self.convert_xobject(doc, id, settings, report)
      stream = doc.objects[id]
      return unless stream && stream.stream?
      result = convert(doc, stream.dict, stream, nil, settings)
      return if result.nil?

      # /Matte is expressed in the parent image's color space.
      matte_id = -1
      matte_gray = 0.0
      smask = stream.dict["SMask"]
      if smask && smask.ref?
        target = doc.objects[smask.num]
        if target && target.stream?
          m = doc.dget_numbers(target.dict, "Matte")
          cs = stream.dict["ColorSpace"]
          if m && cs
            space = ColorSpace.resolve(doc, cs, nil, settings.max_stream_bytes)
            g = space.to_gray(m, settings.gray_model)
            unless g.nil?
              matte_id = smask.num
              matte_gray = settings.tone.apply(g)
            end
          end
        end
      end

      if result.kind == ImageResult::PALETTE
        space = Obj.array([
          Obj.name("Indexed"), Obj.name("DeviceGray"),
          Obj.int(result.hival), Obj.string(result.lookup, true)
        ])
        stream.dict["ColorSpace"] = space
      else
        mask_id = -1
        unless result.soft_mask.nil?
          mask_stream = Streams.flate_stream(
            gray_image_dict(result.width, result.height, 8), result.soft_mask
          )
          mask_id = doc.add(mask_stream)
        end
        stream.dict.delete("Decode")
        # Color key ranges refer to the original components.
        m = stream.dict["Mask"]
        stream.dict.delete("Mask") if m && m.array?
        gray_image_dict(result.width, result.height, result.bits).each do |k, v|
          stream.dict[k] = v
        end
        stream.dict["SMask"] = Obj.ref(mask_id, 0) if mask_id > 0
        Streams.set_flate_content(stream, result.data)
      end

      if matte_id > 0
        target = doc.objects[matte_id]
        if target && target.stream?
          target.dict["Matte"] = Obj.array([Obj.real(matte_gray)])
        end
      end
      report.images = report.images + 1
    end
  end

  FULL_KEYS = {
    "BPC" => "BitsPerComponent",
    "CS" => "ColorSpace",
    "D" => "Decode",
    "DP" => "DecodeParms",
    "F" => "Filter",
    "H" => "Height",
    "IM" => "ImageMask",
    "I" => "Interpolate",
    "W" => "Width",
  }

  # An inline image (`BI … ID … EI`) found in a content stream.
  class InlineImage
    attr_reader :raw, :normalized, :unfiltered_len

    def self.full_key(key)
      FULL_KEYS.fetch(key, key)
    end

    def initialize(env, raw)
      @raw = raw
      normalized = {}
      raw.each do |key, value|
        full = InlineImage.full_key(key)
        v = value
        if full == "Filter"
          if value.name?
            v = Obj.name(Filters.full_name(value.str))
          elsif value.array?
            items = []
            value.items.each do |o|
              items << (o.name? ? Obj.name(Filters.full_name(o.str)) : o)
            end
            v = Obj.array(items)
          end
        end
        normalized[full] = v
      end
      @normalized = normalized
      @unfiltered_len = compute_length(env)
    end

    def compute_length(env)
      doc = env.doc
      return nil unless doc.filters(@normalized).empty?
      width = doc.dget_int(@normalized, "Width")
      height = doc.dget_int(@normalized, "Height")
      return nil if width.nil? || height.nil?
      components = 1
      bits = 1
      if doc.dget_bool(@normalized, "ImageMask") != true
        cs = @normalized["ColorSpace"]
        return nil if cs.nil?
        space = ColorSpace.resolve(doc, cs, env.resources, env.settings.max_stream_bytes)
        components = space.components
        b = doc.dget_int(@normalized, "BitsPerComponent")
        return nil if b.nil?
        bits = b
      end
      len = ((width * components * bits + 7) / 8) * height
      return nil if len <= 0
      len
    end

    # The replacement `BI … EI` bytes, or nil if the image needs no change.
    def convert(env, data)
      stream = Obj.stream(@normalized, data)
      result = Image.convert(env.doc, @normalized, stream, env.resources, env.settings)
      return nil if result.nil?

      out = Buf.new
      out << "BI"
      if result.kind == ImageResult::PALETTE
        space = Obj.array([
          Obj.name("I"), Obj.name("G"),
          Obj.int(result.hival), Obj.string(result.lookup, true)
        ])
        keys = @raw.keys
        i = 0
        while i < keys.length
          key = keys[i]
          value = @raw[key]
          v = InlineImage.full_key(key) == "ColorSpace" ? space : value
          entry(out, key, v)
          i += 1
        end
        out << " ID "
        out << data
        out << "\nEI"
        return out.to_s
      end

      entry(out, "W", Obj.int(result.width))
      entry(out, "H", Obj.int(result.height))
      entry(out, "CS", Obj.name("G"))
      entry(out, "BPC", Obj.int(result.bits))
      entry(out, "F", Obj.array([Obj.name("AHx"), Obj.name("Fl")]))
      interpolate = @normalized["Interpolate"]
      entry(out, "I", interpolate) if interpolate
      out << " ID "
      # ASCIIHex keeps the data free of bytes that could be mistaken for `EI`.
      packed = Filters.flate(result.data)
      i = 0
      n = packed.bytesize
      while i < n
        out << "\n" if i > 0 && i % 40 == 0
        out << Hex.byte(packed.getbyte(i))
        i += 1
      end
      out << ">\nEI"
      out.to_s
    end

    def entry(out, key, value)
      out << " "
      CWrite.write(out, Obj.name(key))
      out << " "
      CWrite.write(out, value)
    end
  end
end
