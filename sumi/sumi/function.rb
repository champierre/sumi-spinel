# PDF functions (ISO 32000-1, 7.10): needed to evaluate Separation/DeviceN tint
# transforms and shading colors.

module Sumi
  MAX_SAMPLED_INPUTS = 8
  MAX_SAMPLES = 16 * 1024 * 1024
  MAX_PS_STEPS = 100000
  MAX_PS_STACK = 1000

  # One PostScript calculator instruction.
  class PsOp
    NUM = 0
    BOOL = 1
    OP = 2
    IF = 3
    IFELSE = 4

    attr_accessor :kind, :num, :name, :body1, :body2

    def initialize(kind)
      @kind = kind
      @num = 0.0
      @name = nil
      @body1 = nil
      @body2 = nil
    end
  end

  # A parsed function. `ftype` is the PDF /FunctionType, or ARRAY for the
  # array-of-functions form shadings allow.
  class Function
    ARRAY = -1

    attr_accessor :ftype, :domain, :range, :size, :bits, :encode, :decode,
                  :samples, :c0, :c1, :nexp, :functions, :bounds, :program

    def initialize(ftype)
      @ftype = ftype
      @domain = []     # flat lo, hi pairs
      @range = []      # flat lo, hi pairs
      @size = []
      @bits = 8
      @encode = []
      @decode = []
      @samples = nil
      @c0 = []
      @c1 = []
      @nexp = 1.0
      @functions = []
      @bounds = []
      @program = nil
    end

    def self.interpolate(x, x0, x1, y0, y1)
      return y0 if x1 == x0
      y0 + (x - x0) * (y1 - y0) / (x1 - x0)
    end

    def self.clip(x, lo, hi)
      if lo > hi
        t = lo
        lo = hi
        hi = t
      end
      return lo if x.nan?
      return lo if x < lo
      return hi if x > hi
      x
    end

    def self.clip_outputs(out, range)
      i = 0
      while i < out.length && 2 * i + 1 < range.length
        out[i] = clip(out[i], range[2 * i], range[2 * i + 1])
        i += 1
      end
      out
    end

    # The input domain of the first input.
    def domain_pair
      return [0.0, 1.0] if @ftype == ARRAY && @functions.empty?
      return @functions[0].domain_pair if @ftype == ARRAY
      return [0.0, 1.0] if @domain.length < 2
      [@domain[0], @domain[1]]
    end

    # The 2-D input domain of a function with two inputs, or nil.
    def domain2
      if @ftype == ARRAY
        return nil if @functions.empty?
        return @functions[0].domain2
      end
      return nil unless @ftype == 0 || @ftype == 4
      return nil if @domain.length < 4
      [@domain[0], @domain[1], @domain[2], @domain[3]]
    end

    def eval(input)
      case @ftype
      when 0 then eval_sampled(input)
      when 2 then eval_exponential(input)
      when 3 then eval_stitching(input)
      when 4 then eval_postscript(input)
      else
        out = []
        @functions.each do |f|
          f.eval(input).each { |v| out << v }
        end
        out
      end
    end

    def eval_exponential(input)
      x = Function.clip(input.empty? ? 0.0 : input[0], @domain[0], @domain[1])
      xn = x ** @nexp
      out = []
      i = 0
      while i < @c0.length && i < @c1.length
        out << @c0[i] + xn * (@c1[i] - @c0[i])
        i += 1
      end
      Function.clip_outputs(out, @range)
    end

    def eval_stitching(input)
      x = Function.clip(input.empty? ? 0.0 : input[0], @domain[0], @domain[1])
      k = @bounds.length
      i = 0
      while i < @bounds.length
        if x < @bounds[i]
          k = i
          break
        end
        i += 1
      end
      lo = k == 0 ? @domain[0] : @bounds[k - 1]
      hi = k == @bounds.length ? @domain[1] : @bounds[k]
      t = Function.interpolate(x, lo, hi, @encode[2 * k], @encode[2 * k + 1])
      Function.clip_outputs(@functions[k].eval([t]), @range)
    end

    def sample_at(index)
      bits = @bits
      start = index * bits
      value = 0
      i = 0
      while i < bits
        bit = start + i
        byte = bit >> 3
        b = byte < @samples.bytesize ? @samples.getbyte(byte) : 0
        value = (value << 1) | ((b >> (7 - (bit & 7))) & 1)
        i += 1
      end
      value.to_f
    end

    def eval_sampled(input)
      m = @size.length
      n = @range.length / 2
      base = []
      frac = []
      i = 0
      while i < m
        x = Function.clip(i < input.length ? input[i] : 0.0,
                          @domain[2 * i], @domain[2 * i + 1])
        e = Function.interpolate(x, @domain[2 * i], @domain[2 * i + 1],
                                 @encode[2 * i], @encode[2 * i + 1])
        e = Function.clip(e, 0.0, (@size[i] - 1).to_f)
        top = @size[i] - 2
        top = 0 if top < 0
        fl = e.floor.to_i
        fl = top if fl > top
        fl = 0 if fl < 0
        base << fl
        frac << (@size[i] == 1 ? 0.0 : e - fl.to_f)
        i += 1
      end

      max_sample = ((1 << @bits) - 1).to_f
      out = []
      j = 0
      while j < n
        out << 0.0
        j += 1
      end
      corners = 1 << m
      corner = 0
      while corner < corners
        weight = 1.0
        index = 0
        stride = 1
        i = 0
        while i < m
          upper = ((corner >> i) & 1) == 1
          coord = upper && @size[i] > 1 ? base[i] + 1 : base[i]
          weight *= upper ? frac[i] : 1.0 - frac[i]
          index += coord * stride
          stride *= @size[i]
          i += 1
        end
        if weight != 0.0
          j = 0
          while j < n
            out[j] = out[j] + weight * sample_at(index * n + j)
            j += 1
          end
        end
        corner += 1
      end
      j = 0
      while j < n
        out[j] = Function.interpolate(out[j], 0.0, max_sample,
                                      @decode[2 * j], @decode[2 * j + 1])
        j += 1
      end
      Function.clip_outputs(out, @range)
    end

    def eval_postscript(input)
      stack = []
      flags = []
      i = 0
      count = @domain.length / 2
      while i < count
        stack << Function.clip(i < input.length ? input[i] : 0.0,
                               @domain[2 * i], @domain[2 * i + 1])
        flags << 0
        i += 1
      end
      steps = [0]
      # A failing program yields whatever is on the stack, like most viewers.
      Ps.run(@program, stack, flags, steps)
      n = @range.length / 2
      out = []
      start = stack.length - n
      start = 0 if start < 0
      k = start
      while k < stack.length
        out << stack[k]
        k += 1
      end
      out.unshift(0.0) while out.length < n
      Function.clip_outputs(out, @range)
    end
  end
end
