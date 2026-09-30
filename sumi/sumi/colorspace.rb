# Color space resolution (ISO 32000-1, 8.6).

module Sumi
  class ColorSpace
    GRAY = 0
    RGB = 1
    CMYK = 2
    LAB = 3
    INDEXED = 4
    SEPARATION = 5
    DEVICEN = 6
    PATTERN = 7
    UNSUPPORTED = 8

    # Tint kinds for Separation / DeviceN.
    NO_INK = 0
    ALL = 1
    TRANSFORM = 2

    attr_accessor :kind, :base, :hival, :lookup, :tint, :alternate, :function,
                  :ncomps, :reason

    def initialize(kind)
      @kind = kind
      @base = nil
      @hival = 0
      @lookup = nil
      @tint = TRANSFORM
      @alternate = nil
      @function = nil
      @ncomps = 0
      @reason = nil
    end

    def self.simple(kind) = ColorSpace.new(kind)

    def self.unsupported(reason)
      cs = ColorSpace.new(UNSUPPORTED)
      cs.reason = reason
      cs
    end

    def components
      case @kind
      when GRAY, INDEXED, SEPARATION then 1
      when RGB, LAB then 3
      when CMYK then 4
      when DEVICEN then @ncomps
      when PATTERN then @base.nil? ? 0 : @base.components
      else 0
      end
    end

    def gray? = @kind == GRAY

    # Whether colors in this space can be mapped to gray.
    def convertible?
      return @tint != NO_INK if @kind == SEPARATION || @kind == DEVICEN
      return false if @kind == PATTERN || @kind == UNSUPPORTED
      true
    end

    # The color `cs`/`CS` selects (ISO 32000-1, table 74).
    def initial_color
      return [0.0, 0.0, 0.0, 1.0] if @kind == CMYK
      return [1.0] if @kind == SEPARATION
      if @kind == DEVICEN
        out = []
        i = 0
        while i < @ncomps
          out << 1.0
          i += 1
        end
        return out
      end
      out = []
      n = components
      i = 0
      while i < n
        out << 0.0
        i += 1
      end
      out
    end

    # Default image /Decode array for `bits` bits per component, flat.
    def default_decode(bits)
      return [0.0, ((1 << bits) - 1).to_f] if @kind == INDEXED
      return [0.0, 100.0, -100.0, 100.0, -100.0, 100.0] if @kind == LAB
      out = []
      n = components
      i = 0
      while i < n
        out << 0.0
        out << 1.0
        i += 1
      end
      out
    end

    def comp(comps, i)
      i < comps.length ? comps[i] : 0.0
    end

    # Maps color components to a gray level in 0.0..1.0, or nil.
    def to_gray(comps, model)
      case @kind
      when GRAY then Color.clamp01(comp(comps, 0))
      when RGB then Color.rgb_to_gray(comp(comps, 0), comp(comps, 1), comp(comps, 2), model)
      when CMYK
        Color.cmyk_to_gray(comp(comps, 0), comp(comps, 1), comp(comps, 2), comp(comps, 3))
      when LAB then Color.lab_to_gray(comp(comps, 0))
      when INDEXED
        idx = comp(comps, 0).round
        idx = 0 if idx < 0
        idx = @hival if idx > @hival
        @base.to_gray(palette_entry(idx), model)
      when SEPARATION, DEVICEN
        return nil if @tint == NO_INK
        if @tint == ALL
          ink = 0.0
          comps.each { |c| ink = c if c > ink }
          return Color.clamp01(1.0 - ink)
        end
        @alternate.to_gray(@function.eval(comps), model)
      else
        nil
      end
    end

    # The base-space components of one palette entry.
    def palette_entry(index)
      n = @base.components
      decode = @base.default_decode(8)
      out = []
      j = 0
      while j < n
        at = index * n + j
        byte = at < @lookup.bytesize ? @lookup.getbyte(at).to_f : 0.0
        lo = 2 * j + 1 < decode.length ? decode[2 * j] : 0.0
        hi = 2 * j + 1 < decode.length ? decode[2 * j + 1] : 1.0
        out << lo + byte * (hi - lo) / 255.0
        j += 1
      end
      out
    end

    # The gray level of every palette entry of an indexed color space, or nil.
    def palette_grays(model)
      return nil unless @kind == INDEXED
      out = []
      i = 0
      while i <= @hival
        g = @base.to_gray(palette_entry(i), model)
        return nil if g.nil?
        out << g
        i += 1
      end
      out
    end

    def kind_name
      case @kind
      when GRAY then "DeviceGray"
      when RGB then "DeviceRGB"
      when CMYK then "DeviceCMYK"
      when LAB then "Lab"
      when INDEXED then "Indexed"
      when SEPARATION then "Separation"
      when DEVICEN then "DeviceN"
      when PATTERN then "Pattern"
      else @reason.nil? ? "unsupported" : @reason
      end
    end

    # ---- resolution ---------------------------------------------------

    # Resolves a color space operand or dictionary value. Names that are not
    # color space families are looked up in the /ColorSpace resources.
    def self.resolve(doc, obj, resources, limit)
      begin
        return resolve_depth(doc, obj, resources, limit, 0)
      rescue Filters::DecodeError => e
        return unsupported(e.message)
      rescue Filters::UnsupportedError => e
        return unsupported(e.message)
      rescue Filters::LimitError => e
        return unsupported(e.message)
      end
    end

    def self.resolve_depth(doc, obj, resources, limit, depth)
      raise Filters::DecodeError, "color space nested too deeply" if depth > 8
      o = doc.resolve(obj)
      family = nil
      array = []
      if o.name?
        family = o.str
      elsif o.array?
        first = o.items.empty? ? nil : doc.resolve(o.items[0])
        raise Filters::DecodeError, "malformed color space array" if first.nil? || !first.name?
        family = first.str
        array = o.items[1, o.items.length - 1]
      else
        raise Filters::DecodeError, "malformed color space"
      end

      case family
      when "DeviceGray", "G", "CalGray" then return simple(GRAY)
      when "DeviceRGB", "RGB", "CalRGB" then return simple(RGB)
      when "DeviceCMYK", "CMYK", "CalCMYK" then return simple(CMYK)
      when "Lab" then return simple(LAB)
      when "ICCBased" then return resolve_icc(doc, array, limit, depth)
      when "Indexed", "I" then return resolve_indexed(doc, array, resources, limit, depth)
      when "Separation" then return resolve_separation(doc, array, limit, depth)
      when "DeviceN" then return resolve_devicen(doc, array, limit, depth)
      when "Pattern"
        cs = ColorSpace.new(PATTERN)
        unless array.empty?
          cs.base = resolve_depth(doc, array[0], resources, limit, depth + 1)
        end
        return cs
      end

      if array.empty?
        spaces = resources.nil? ? nil : doc.dget_dict(resources, "ColorSpace")
        value = spaces.nil? ? nil : spaces[family]
        if value.nil?
          raise Filters::DecodeError, "color space /#{family} not found in resources"
        end
        # Resource entries may not refer to other resource names.
        return resolve_depth(doc, value, nil, limit, depth + 1)
      end
      raise Filters::UnsupportedError, "#{family} color space"
    end

    def self.param(doc, array, i)
      return nil if i >= array.length
      doc.resolve(array[i])
    end

    def self.resolve_icc(doc, array, limit, depth)
      stream = param(doc, array, 0)
      dict = stream.nil? ? nil : stream.as_dict
      raise Filters::DecodeError, "ICCBased color space without a stream" if dict.nil?
      n = doc.dget_int(dict, "N")
      return simple(GRAY) if n == 1
      return simple(RGB) if n == 3
      return simple(CMYK) if n == 4
      alt = doc.dget(dict, "Alternate")
      raise Filters::DecodeError, "ICCBased color space without /N" if alt.nil?
      resolve_depth(doc, alt, nil, limit, depth + 1)
    end

    def self.resolve_indexed(doc, array, resources, limit, depth)
      base_obj = param(doc, array, 0)
      raise Filters::DecodeError, "Indexed color space without a base" if base_obj.nil?
      base = resolve_depth(doc, base_obj, resources, limit, depth + 1)
      if !base.convertible? || base.kind == INDEXED
        raise Filters::UnsupportedError, "Indexed color space with a #{base.kind_name} base"
      end
      hival_obj = param(doc, array, 1)
      if hival_obj.nil? || !hival_obj.number?
        raise Filters::DecodeError, "Indexed color space without hival"
      end
      hival = hival_obj.to_f
      hival = 0.0 if hival < 0.0
      hival = 255.0 if hival > 255.0
      hival = hival.to_i
      lookup_obj = param(doc, array, 2)
      lookup = nil
      if lookup_obj && lookup_obj.str?
        lookup = lookup_obj.str
      elsif lookup_obj && lookup_obj.stream?
        lookup = doc.decode_stream_obj(lookup_obj, limit)
      else
        raise Filters::DecodeError, "Indexed color space without a lookup table"
      end
      need = (hival + 1) * base.components
      lookup = lookup + ("\0" * (need - lookup.bytesize)) if lookup.bytesize < need
      cs = ColorSpace.new(INDEXED)
      cs.base = base
      cs.hival = hival
      cs.lookup = lookup
      cs
    end

    def self.resolve_separation(doc, array, limit, depth)
      cs = ColorSpace.new(SEPARATION)
      name = param(doc, array, 0)
      if name && name.name? && name.str == "None"
        cs.tint = NO_INK
        return cs
      end
      if name && name.name? && name.str == "All"
        cs.tint = ALL
        return cs
      end
      apply_tint(doc, cs, array, limit, depth)
      cs
    end

    def self.resolve_devicen(doc, array, limit, depth)
      names = param(doc, array, 0)
      if names.nil? || !names.array? || names.items.empty? || names.items.length > 32
        raise Filters::DecodeError, "DeviceN color space without colorant names"
      end
      cs = ColorSpace.new(DEVICEN)
      cs.ncomps = names.items.length
      no_ink = true
      names.items.each do |n|
        r = doc.resolve(n)
        no_ink = false unless r.name? && r.str == "None"
      end
      if no_ink
        cs.tint = NO_INK
        return cs
      end
      apply_tint(doc, cs, array, limit, depth)
      cs
    end

    def self.apply_tint(doc, cs, array, limit, depth)
      alt = param(doc, array, 1)
      if alt.nil?
        raise Filters::DecodeError, "special color space without an alternate space"
      end
      alternate = resolve_depth(doc, alt, nil, limit, depth + 1)
      if !alternate.convertible? || alternate.kind == INDEXED
        raise Filters::UnsupportedError, "alternate color space #{alternate.kind_name}"
      end
      fn = param(doc, array, 2)
      if fn.nil?
        raise Filters::DecodeError, "special color space without a tint transform"
      end
      cs.tint = TRANSFORM
      cs.alternate = alternate
      cs.function = FuncParse.parse(doc, fn, limit)
      cs
    end
  end
end
