# Rewrites color operators in content streams.
#
# Only the bytes of color operators (and convertible inline images) are
# replaced; everything else, including text, paths, strings and comments, is
# copied verbatim.

module Sumi
  class Env
    attr_accessor :doc, :resources, :settings, :pattern_gray_name, :inherited_state

    def initialize(doc, resources, settings, pattern_gray_name, inherited_state)
      @doc = doc
      @resources = resources
      @settings = settings
      @pattern_gray_name = pattern_gray_name
      @inherited_state = inherited_state
    end
  end

  class Output
    attr_accessor :data, :changed, :uses_pattern_gray

    def initialize
      @data = nil
      @changed = false
      @uses_pattern_gray = false
    end
  end

  class GState
    attr_accessor :fill, :stroke

    def initialize(fill, stroke)
      @fill = fill
      @stroke = stroke
    end

    def copy = GState.new(@fill, @stroke)
  end

  MAX_STATE_DEPTH = 1024

  class Rewriter
    def initialize(input, env, report)
      @input = input
      @env = env
      @report = report
      @out = Buf.new
      @copied = 0
      @changed = false
      @uses_pattern_gray = false
      @spaces = {}
      initial = env.inherited_state ? nil : ColorSpace.simple(ColorSpace::GRAY)
      @state = GState.new(initial, initial)
      @stack = []
      @op_kind = []
      @op_start = []
      @op_stop = []
      @values = []
    end

    def self.rewrite(input, env, report)
      rw = Rewriter.new(input, env, report)
      rw.run
    end

    def run
      lexer = ContentLexer.new(@input)
      # Operands as three parallel Integer arrays: a content stream holds
      # millions of tokens and an object per token is what used to cost.
      kinds = @op_kind
      starts = @op_start
      stops = @op_stop
      while lexer.advance
        kind = lexer.kind
        if kind != Token::KEYWORD
          kinds << kind
          starts << lexer.tstart
          stops << lexer.tstop
          next
        end
        op_start = lexer.tstart
        op_stop = lexer.tstop
        n = op_stop - op_start
        b0 = @input.getbyte(op_start)
        handled = true
        if n == 1
          case b0
          when 0x71 then push_state          # q
          when 0x51 then pop_state           # Q
          when 0x67 then device_color(lexer, op_stop, 1, false)  # g
          when 0x47 then device_color(lexer, op_stop, 1, true)   # G
          when 0x6b then device_color(lexer, op_stop, 4, false)  # k
          when 0x4b then device_color(lexer, op_stop, 4, true)   # K
          else handled = false
          end
        elsif n == 2
          b1 = @input.getbyte(op_start + 1)
          if b0 == 0x72 && b1 == 0x67
            device_color(lexer, op_stop, 3, false)               # rg
          elsif b0 == 0x52 && b1 == 0x47
            device_color(lexer, op_stop, 3, true)                # RG
          elsif b0 == 0x63 && b1 == 0x73
            set_space(lexer, op_stop, false)                     # cs
          elsif b0 == 0x43 && b1 == 0x53
            set_space(lexer, op_stop, true)                      # CS
          elsif b0 == 0x73 && b1 == 0x63
            set_color(lexer, op_stop, false)                     # sc
          elsif b0 == 0x53 && b1 == 0x43
            set_color(lexer, op_stop, true)                      # SC
          elsif b0 == 0x42 && b1 == 0x49
            inline_image(lexer, op_start)                        # BI
          else
            handled = false
          end
        elsif n == 3
          if lexer.keyword?("scn")
            set_color(lexer, op_stop, false)
          elsif lexer.keyword?("SCN")
            set_color(lexer, op_stop, true)
          else
            handled = false
          end
        else
          handled = false
        end
        unless handled
          # `true`, `false` and `null` are operands, not operators.
          if n == 4 && (lexer.keyword?("true") || lexer.keyword?("null"))
            kinds << kind
            starts << op_start
            stops << op_stop
            next
          end
          if n == 5 && lexer.keyword?("false")
            kinds << kind
            starts << op_start
            stops << op_stop
            next
          end
        end
        kinds.clear
        starts.clear
        stops.clear
      end

      result = Output.new
      @out << @input.byteslice(@copied, @input.bytesize - @copied) if @changed
      result.data = @out.to_s
      result.changed = @changed
      result.uses_pattern_gray = @uses_pattern_gray
      result
    end

    def push_state
      @stack << @state.copy if @stack.length < MAX_STATE_DEPTH
    end

    def pop_state
      @state = @stack.pop unless @stack.empty?
    end

    def replace(start, stop, text)
      return if start < @copied || stop < start
      @out << @input.byteslice(@copied, start - @copied)
      if start > 0 && Lex.regular?(@input.getbyte(start - 1)) &&
         text.bytesize > 0 && Lex.regular?(text.getbyte(0))
        @out << " "
      end
      @out << text
      if stop < @input.bytesize && Lex.regular?(@input.getbyte(stop)) &&
         text.bytesize > 0 && Lex.regular?(text.getbyte(text.bytesize - 1))
        @out << " "
      end
      @copied = stop
      @changed = true
    end

    def current(stroke)
      stroke ? @state.stroke : @state.fill
    end

    def set_current(stroke, space)
      if stroke
        @state.stroke = space
      else
        @state.fill = space
      end
    end

    # The trailing `n` operands, when they are all numbers. The values land in
    # `@values`; the answer is the byte offset of the first, or -1.
    def trailing_numbers(n, upto)
      return -1 if n == 0 || upto < n
      first = upto - n
      @values.clear
      i = first
      while i < upto
        return -1 unless @op_kind[i] == Token::NUMBER
        @values << Numbers.to_f(@input.byteslice(@op_start[i], @op_stop[i] - @op_start[i]))
        i += 1
      end
      @op_start[first]
    end

    def device_color(lexer, op_stop, n, stroke)
      set_current(stroke, ColorSpace.simple(ColorSpace::GRAY))
      start = trailing_numbers(n, @op_kind.length)
      return if start < 0
      tone = @env.settings.tone
      model = @env.settings.gray_model
      return if n == 1 && !tone.monochrome?
      space = ColorSpace.simple(n == 1 ? ColorSpace::GRAY : (n == 3 ? ColorSpace::RGB : ColorSpace::CMYK))
      g = space.to_gray(@values, model)
      gray = tone.apply(g.nil? ? 0.0 : g)
      text = Color.format_number(gray) + (stroke ? " G" : " g")
      replace(start, op_stop, text)
      @report.color_operators = @report.color_operators + 1
    end

    def resolve_space(name)
      cached = @spaces[name]
      return cached unless cached.nil?
      space = ColorSpace.resolve(@env.doc, Obj.name(name), @env.resources,
                                 @env.settings.max_stream_bytes)
      @spaces[name] = space
      space
    end

    def set_space(lexer, op_stop, stroke)
      count = @op_kind.length
      return if count == 0
      last = count - 1
      return unless @op_kind[last] == Token::NAME
      name_start = @op_start[last]
      raw = @input.byteslice(name_start + 1, @op_stop[last] - name_start - 1)
      name = Names.decode(raw)
      space = resolve_space(name)
      set_current(stroke, space)
      tone = @env.settings.tone
      model = @env.settings.gray_model
      cs_op = stroke ? "CS" : "cs"
      sc_op = stroke ? "SC" : "sc"

      if space.kind == ColorSpace::PATTERN
        base = space.base
        return if base.nil?
        if base.convertible?
          text = "/" + @env.pattern_gray_name + " " + cs_op
          replace(name_start, op_stop, text)
          @uses_pattern_gray = true
          @report.color_operators = @report.color_operators + 1
        elsif base.kind == ColorSpace::UNSUPPORTED
          @report.warn("pattern color space not converted: #{base.reason}")
        end
        return
      end
      if space.kind == ColorSpace::UNSUPPORTED
        @report.warn("color space not converted: #{space.reason}")
        return
      end
      return unless space.convertible?
      return if space.gray?
      g = space.to_gray(space.initial_color, model)
      gray = tone.apply(g.nil? ? 0.0 : g)
      text = "/DeviceGray " + cs_op
      text = text + " " + Color.format_number(gray) + " " + sc_op if gray != 0.0
      replace(name_start, op_stop, text)
      @report.color_operators = @report.color_operators + 1
    end

    def set_color(lexer, op_stop, stroke)
      total = @op_kind.length
      pattern = -1
      if total > 0 && @op_kind[total - 1] == Token::NAME
        pattern = total - 1
      end
      numeric_len = pattern < 0 ? total : total - 1
      count = 0
      i = numeric_len - 1
      while i >= 0 && @op_kind[i] == Token::NUMBER
        count += 1
        i -= 1
      end
      start = trailing_numbers(count, numeric_len)
      return if start < 0
      tone = @env.settings.tone
      model = @env.settings.gray_model
      space = current(stroke)

      if pattern >= 0
        return if space.nil? || space.kind != ColorSpace::PATTERN
        base = space.base
        return if base.nil?
        return if count != base.components || !base.convertible?
        g = base.to_gray(@values, model)
        gray = tone.apply(g.nil? ? 0.0 : g)
        text = Buf.new
        text << Color.format_number(gray) << " "
        text << @input.byteslice(@op_start[pattern], @op_stop[pattern] - @op_start[pattern])
        text << " " << lexer.token_text
        replace(start, op_stop, text.to_s)
        @report.color_operators = @report.color_operators + 1
        return
      end

      use = nil
      if space && space.convertible? && space.components == count
        use = space
      elsif space && !space.convertible?
        return
      else
        use = ColorSpace.simple(ColorSpace::GRAY) if count == 1
        use = ColorSpace.simple(ColorSpace::RGB) if count == 3
        use = ColorSpace.simple(ColorSpace::CMYK) if count == 4
        return if use.nil?
      end
      return if use.gray? && !tone.monochrome?
      g = use.to_gray(@values, model)
      return if g.nil?
      text = Color.format_number(tone.apply(g)) + " " + lexer.token_text
      replace(start, op_stop, text)
      @report.color_operators = @report.color_operators + 1
    end

    def inline_image(lexer, bi_start)
      tokens = []
      while true
        return unless lexer.advance
        break if lexer.kind == Token::KEYWORD && lexer.keyword?("ID")
        tokens << lexer.current_token
      end

      d = {}
      index = [0]
      while index[0] < tokens.length
        key_token = tokens[index[0]]
        index[0] = index[0] + 1
        next unless key_token.kind == Token::NAME
        raw = lexer.text(key_token)
        key = Names.decode(raw.byteslice(1, raw.bytesize - 1))
        value = lexer.parse_object(tokens, index, 0)
        break if value.nil?
        d[key] = value
      end

      image = InlineImage.new(@env, d)
      span = lexer.inline_image_data(image.unfiltered_len)
      data = lexer.data.byteslice(span[0], span[1] - span[0])
      begin
        bytes = image.convert(@env, data)
        unless bytes.nil?
          replace(bi_start, span[2], bytes)
          @report.images = @report.images + 1
        end
      rescue Filters::LimitError => e
        raise e
      rescue Filters::DecodeError => e
        @report.warn("inline image not converted: #{e.message}")
      rescue Filters::UnsupportedError => e
        @report.warn("inline image not converted: #{e.message}")
      end
    end
  end
end
