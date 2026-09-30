# Converts shadings (gradients).
#
# The original color function is sampled and replaced by a gray sampled
# function, so axial, radial and function-based shadings keep their geometry.

module Sumi
  SAMPLES_1D = 256
  SAMPLES_2D = 33

  class ShadingPlan
    attr_accessor :function, :background

    def initialize(function, background)
      @function = function
      @background = background
    end
  end

  module Shading
    # Returns a ShadingPlan, or nil when the shading needs no change.
    def self.plan(doc, dict, settings)
      tone = settings.tone
      limit = settings.max_stream_bytes
      shading_type = doc.dget_int(dict, "ShadingType")
      raise Filters::DecodeError, "shading without /ShadingType" if shading_type.nil?
      cs = doc.dget_raw(dict, "ColorSpace")
      raise Filters::DecodeError, "shading without /ColorSpace" if cs.nil?
      space = ColorSpace.resolve(doc, cs, nil, limit)
      if space.kind == ColorSpace::UNSUPPORTED
        raise Filters::UnsupportedError, "shading color space #{space.reason}"
      end
      return nil unless space.convertible?
      return nil if space.gray? && !tone.monochrome?

      fn = doc.dget(dict, "Function")
      if fn.nil?
        raise Filters::UnsupportedError,
              "type #{shading_type} mesh shading without a function"
      end
      function = FuncParse.parse(doc, fn, limit)

      fd = {}
      fd["FunctionType"] = Obj.int(0)
      fd["BitsPerSample"] = Obj.int(8)
      fd["Range"] = Obj.array([Obj.int(0), Obj.int(1)])

      samples = String.new
      if shading_type == 1
        d = doc.dget_numbers(dict, "Domain")
        d = nil if d && d.length < 4
        if d.nil?
          d2 = function.domain2
          d = d2.nil? ? [0.0, 1.0, 0.0, 1.0] : d2
        end
        fd["Domain"] = reals([d[0], d[1], d[2], d[3]])
        fd["Size"] = Obj.array([Obj.int(SAMPLES_2D), Obj.int(SAMPLES_2D)])
        j = 0
        while j < SAMPLES_2D
          y = d[2] + (d[3] - d[2]) * j.to_f / (SAMPLES_2D - 1).to_f
          i = 0
          while i < SAMPLES_2D
            x = d[0] + (d[1] - d[0]) * i.to_f / (SAMPLES_2D - 1).to_f
            samples << gray_byte(space, function, [x, y], settings).chr
            i += 1
          end
          j += 1
        end
      elsif shading_type >= 2 && shading_type <= 7
        d = nil
        if shading_type == 2 || shading_type == 3
          nums = doc.dget_numbers(dict, "Domain")
          d = [nums[0], nums[1]] if nums && nums.length >= 2
        end
        d = function.domain_pair if d.nil?
        fd["Domain"] = reals(d)
        fd["Size"] = Obj.array([Obj.int(SAMPLES_1D)])
        i = 0
        while i < SAMPLES_1D
          x = d[0] + (d[1] - d[0]) * i.to_f / (SAMPLES_1D - 1).to_f
          samples << gray_byte(space, function, [x], settings).chr
          i += 1
        end
      else
        raise Filters::DecodeError, "unknown shading type #{shading_type}"
      end

      background = nil
      bg = doc.dget_numbers(dict, "Background")
      if bg
        g = space.to_gray(bg, settings.gray_model)
        background = Obj.array([Obj.real(tone.apply(g))]) unless g.nil?
      end

      ShadingPlan.new(Streams.flate_stream(fd, samples), background)
    end

    def self.gray_byte(space, function, input, settings)
      g = space.to_gray(function.eval(input), settings.gray_model)
      (settings.tone.apply(g.nil? ? 0.0 : g) * 255.0).round
    end

    def self.reals(values)
      items = []
      values.each { |v| items << Obj.real(v) }
      Obj.array(items)
    end
  end

  module Streams
    # A Flate-compressed stream.
    def self.flate_stream(dict, data)
      dict.delete("DecodeParms")
      dict["Filter"] = Obj.name("FlateDecode")
      o = Obj.stream(dict, Filters.flate(data))
      o.allow_compress = false
      o
    end

    # Replaces a stream's data with Flate-compressed `data`.
    def self.set_flate_content(stream, data)
      stream.dict.delete("DecodeParms")
      stream.dict["Filter"] = Obj.name("FlateDecode")
      stream.raw = Filters.flate(data)
      stream.allow_compress = false
    end
  end
end
