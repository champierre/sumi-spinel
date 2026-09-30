# Reads a /Function dictionary or array into a Function.

module Sumi
  module FuncParse
    def self.parse(doc, obj, limit)
      parse_depth(doc, obj, limit, 0)
    end

    def self.parse_depth(doc, obj, limit, depth)
      raise Filters::DecodeError, "functions nested too deeply" if depth > 16
      o = doc.resolve(obj)
      if o.array?
        f = Function.new(Function::ARRAY)
        o.items.each { |it| f.functions << parse_depth(doc, it, limit, depth + 1) }
        return f
      end
      dict = o.as_dict
      raise Filters::DecodeError, "function is not a dictionary" if dict.nil?
      domain = doc.dget_numbers(dict, "Domain")
      domain = [0.0, 1.0] if domain.nil?
      domain = domain[0, domain.length - (domain.length % 2)]
      range = doc.dget_numbers(dict, "Range")
      range = [] if range.nil?
      range = range[0, range.length - (range.length % 2)]
      raise Filters::DecodeError, "function without /Domain" if domain.length < 2

      ftype = doc.dget_int(dict, "FunctionType")
      raise Filters::UnsupportedError, "unknown function type" if ftype.nil?
      case ftype
      when 0 then parse_sampled(doc, o, dict, domain, range, limit)
      when 2 then parse_exponential(doc, dict, domain, range)
      when 3 then parse_stitching(doc, dict, domain, range, limit, depth)
      when 4 then parse_postscript(doc, o, dict, domain, range, limit)
      else
        raise Filters::UnsupportedError, "unknown function type"
      end
    end

    def self.parse_sampled(doc, o, dict, domain, range, limit)
      raise Filters::DecodeError, "sampled function is not a stream" unless o.stream?
      f = Function.new(0)
      f.domain = domain
      f.range = range
      sizes = doc.dget_numbers(dict, "Size")
      sizes = [] if sizes.nil?
      sizes.each do |s|
        v = s < 1.0 ? 1 : s.to_i
        f.size << v
      end
      bits = doc.dget_int(dict, "BitsPerSample")
      f.bits = bits.nil? ? 8 : bits
      inputs = domain.length / 2
      if f.size.length != inputs || f.size.length > MAX_SAMPLED_INPUTS || range.empty?
        raise Filters::DecodeError, "malformed sampled function"
      end
      ok = f.bits == 1 || f.bits == 2 || f.bits == 4 || f.bits == 8 ||
           f.bits == 12 || f.bits == 16 || f.bits == 24 || f.bits == 32
      raise Filters::DecodeError, "unsupported BitsPerSample in sampled function" unless ok
      outputs = range.length / 2
      count = outputs
      f.size.each { |s| count *= s }
      raise Filters::DecodeError, "sampled function is too large" if count > MAX_SAMPLES || count < 0
      encode = doc.dget_numbers(dict, "Encode")
      if encode.nil?
        encode = []
        f.size.each do |s|
          encode << 0.0
          encode << (s - 1).to_f
        end
      end
      decode = doc.dget_numbers(dict, "Decode")
      decode = range if decode.nil?
      if encode.length < 2 * f.size.length || decode.length < 2 * outputs
        raise Filters::DecodeError, "malformed sampled function"
      end
      f.encode = encode
      f.decode = decode
      samples = doc.decode_stream_obj(o, limit)
      needed = (count * f.bits + 7) / 8
      samples = samples + ("\0" * (needed - samples.bytesize)) if samples.bytesize < needed
      f.samples = samples
      f
    end

    def self.parse_exponential(doc, dict, domain, range)
      f = Function.new(2)
      f.domain = [domain[0], domain[1]]
      f.range = range
      c0 = doc.dget_numbers(dict, "C0")
      c1 = doc.dget_numbers(dict, "C1")
      f.c0 = c0.nil? ? [0.0] : c0
      f.c1 = c1.nil? ? [1.0] : c1
      n = doc.dget_number(dict, "N")
      raise Filters::DecodeError, "exponential function without /N" if n.nil?
      f.nexp = n
      f
    end

    def self.parse_stitching(doc, dict, domain, range, limit, depth)
      f = Function.new(3)
      f.domain = [domain[0], domain[1]]
      f.range = range
      list = doc.dget(dict, "Functions")
      unless list && list.array?
        raise Filters::DecodeError, "stitching function without /Functions"
      end
      list.items.each { |it| f.functions << parse_depth(doc, it, limit, depth + 1) }
      bounds = doc.dget_numbers(dict, "Bounds")
      f.bounds = bounds.nil? ? [] : bounds
      encode = doc.dget_numbers(dict, "Encode")
      encode = [] if encode.nil?
      f.encode = encode[0, encode.length - (encode.length % 2)]
      if f.functions.empty? || f.bounds.length + 1 != f.functions.length ||
         f.encode.length / 2 < f.functions.length
        raise Filters::DecodeError, "malformed stitching function"
      end
      f
    end

    def self.parse_postscript(doc, o, dict, domain, range, limit)
      raise Filters::DecodeError, "PostScript function is not a stream" unless o.stream?
      f = Function.new(4)
      f.domain = domain
      f.range = range
      code = doc.decode_stream_obj(o, limit)
      f.program = Ps.parse(code)
      f
    end
  end
end
