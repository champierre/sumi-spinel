# Color math shared by content streams, images and shadings.
#
# The RGB and CMYK formulas are the ones the PDF specification gives for
# converting device colors to DeviceGray (ISO 32000-1, 10.3).

module Sumi
  GRAY_LUMA = 0
  GRAY_COLORIMETRIC = 1

  MODE_GRAYSCALE = 0
  MODE_MONOCHROME = 1

  module Color
    def self.clamp01(v)
      return 0.0 if v.nan?
      return 0.0 if v < 0.0
      return 1.0 if v > 1.0
      v
    end

    def self.rgb_to_gray(r, g, b, model)
      if model == GRAY_LUMA
        clamp01(0.30 * r + 0.59 * g + 0.11 * b)
      else
        y = 0.2126 * srgb_to_linear(r) + 0.7152 * srgb_to_linear(g) +
            0.0722 * srgb_to_linear(b)
        linear_to_srgb(y)
      end
    end

    # Decodes an sRGB value to linear light (IEC 61966-2-1).
    def self.srgb_to_linear(v)
      v = clamp01(v)
      return v / 12.92 if v <= 0.04045
      ((v + 0.055) / 1.055) ** 2.4
    end

    def self.linear_to_srgb(y)
      y = clamp01(y)
      return 12.92 * y if y <= 0.0031308
      clamp01(1.055 * (y ** (1.0 / 2.4)) - 0.055)
    end

    def self.cmyk_to_gray(c, m, y, k)
      ink = 0.30 * c + 0.59 * m + 0.11 * y + k
      ink = 1.0 if ink > 1.0
      clamp01(1.0 - ink)
    end

    # Approximates the lightness of a CIE L*a*b* color.
    def self.lab_to_gray(l)
      clamp01(l / 100.0)
    end

    # Integer version of rgb_to_gray for 8-bit samples (77/151/28 of 256).
    def self.rgb8_to_gray(r, g, b)
      (77 * r + 151 * g + 28 * b + 128) >> 8
    end

    def self.cmyk8_to_gray(c, m, y, k)
      ink = ((77 * c + 151 * m + 28 * y + 128) >> 8) + k
      ink = 255 if ink > 255
      255 - ink
    end

    # A number for a content stream: at most four decimals, no exponent,
    # no trailing zeros.
    def self.format_number(v)
      rounded = (v * 10000.0).round / 10000.0
      return "0" if rounded == 0.0 || rounded.nan? || rounded.infinite?
      s = "%.4f" % rounded
      s = s.sub(/0+\z/, "")
      s = s.sub(/\.\z/, "")
      s
    end
  end

  # Lookup tables for 8-bit colorimetric conversion.
  class Srgb8
    # Rec. 709 luminance weights, rounded so that they add up to 65536.
    WR = 13933
    WG = 46871
    WB = 4732

    attr_reader :linear, :encode

    def initialize
      @linear = []
      v = 0
      while v < 256
        @linear << (Color.srgb_to_linear(v.to_f / 255.0) * 65535.0).round
        v += 1
      end
      @encode = []
      y = 0
      while y <= 65535
        @encode << (Color.linear_to_srgb(y.to_f / 65535.0) * 255.0).round
        y += 1
      end
    end

    def gray(r, g, b)
      y = WR * @linear[r] + WG * @linear[g] + WB * @linear[b]
      @encode[(y + 32768) >> 16]
    end
  end

  # Maps a gray level to the output tone for the selected mode.
  class Tone
    EPSILON = 0.000001

    attr_reader :mode, :threshold

    def initialize(mode, threshold)
      @mode = mode
      @threshold = threshold
    end

    def apply(gray)
      g = Color.clamp01(gray)
      return g if @mode == MODE_GRAYSCALE
      g + EPSILON < @threshold ? 0.0 : 1.0
    end

    def monochrome? = @mode == MODE_MONOCHROME
  end

  # Conversion options in the form the converter uses.
  class Settings
    attr_accessor :tone, :gray_model, :dither, :strict
    attr_accessor :max_stream_bytes, :max_image_pixels, :max_depth
    attr_accessor :srgb8

    def initialize
      @tone = Tone.new(MODE_GRAYSCALE, 0.5)
      @gray_model = GRAY_LUMA
      @dither = false
      @strict = false
      @max_stream_bytes = 256 * 1024 * 1024
      @max_image_pixels = 100000000
      @max_depth = 32
      @srgb8 = nil
    end

    # Built on first use: the tables cost 64K entries.
    def tables
      @srgb8 = Srgb8.new if @srgb8.nil?
      @srgb8
    end
  end

  # What a conversion changed.
  class Report
    attr_accessor :pages, :content_streams, :color_operators, :images, :shadings
    attr_reader :warnings, :counts

    def initialize
      @pages = 0
      @content_streams = 0
      @color_operators = 0
      @images = 0
      @shadings = 0
      @warnings = []
      @counts = {}
    end

    def warn(message)
      if @counts.key?(message)
        @counts[message] = @counts[message] + 1
      else
        @counts[message] = 1
        @warnings << message
      end
    end

    def complete? = @warnings.empty?
  end
end
