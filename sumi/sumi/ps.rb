# The PostScript calculator of a type 4 function.

module Sumi
  module Ps
    def self.parse(code)
      # Each brace level collects items; a completed `{ ... }` becomes a
      # procedure that `if` / `ifelse` picks up from the level above.
      levels = []        # Array of Array[PsOp]
      procs = []         # Array of Array[PsOp] pending as procedures, per level
      pending = []       # per level: the procedures seen but not yet consumed
      result = nil
      pos = 0
      n = code.bytesize
      while pos < n
        c = code.getbyte(pos)
        if c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 || c == 0x0c || c == 0
          pos += 1
          next
        end
        if c == 0x25 # '%'
          pos += 1 while pos < n && code.getbyte(pos) != 0x0a && code.getbyte(pos) != 0x0d
          next
        end
        if c == 0x7b # '{'
          raise Filters::DecodeError, "PostScript function nested too deeply" if levels.length > 64
          levels << []
          pending << []
          pos += 1
          next
        end
        if c == 0x7d # '}'
          pos += 1
          raise Filters::DecodeError, "unbalanced PostScript function" if levels.empty?
          ops = levels.pop
          done = pending.pop
          raise Filters::DecodeError, "procedure without if/ifelse" unless done.empty?
          if levels.empty?
            result = ops
            break
          end
          pending[pending.length - 1] << ops
          next
        end
        start = pos
        while pos < n
          b = code.getbyte(pos)
          break if b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 || b == 0x0c || b == 0
          break if b == 0x7b || b == 0x7d || b == 0x25
          pos += 1
        end
        word = code.byteslice(start, pos - start)
        raise Filters::DecodeError, "PostScript function without braces" if levels.empty?
        current = levels[levels.length - 1]
        waiting = pending[pending.length - 1]
        if word == "true" || word == "false"
          op = PsOp.new(PsOp::BOOL)
          op.num = word == "true" ? 1.0 : 0.0
          current << op
        elsif word == "if"
          raise Filters::DecodeError, "if without procedure" if waiting.empty?
          op = PsOp.new(PsOp::IF)
          op.body1 = waiting.pop
          current << op
        elsif word == "ifelse"
          raise Filters::DecodeError, "ifelse without procedures" if waiting.length < 2
          op = PsOp.new(PsOp::IFELSE)
          op.body2 = waiting.pop
          op.body1 = waiting.pop
          current << op
        elsif Numbers.real?(word) || Numbers.integer?(word)
          op = PsOp.new(PsOp::NUM)
          op.num = Numbers.to_f(word)
          current << op
        else
          op = PsOp.new(PsOp::OP)
          op.name = word
          current << op
        end
      end
      raise Filters::DecodeError, "unterminated PostScript function" if result.nil?
      result
    end

    # Runs `program`. `stack` holds the numbers, `flags` marks which entries are
    # booleans. Returns false when the program ran out of operands or budget.
    def self.run(program, stack, flags, steps)
      i = 0
      while i < program.length
        op = program[i]
        i += 1
        steps[0] = steps[0] + 1
        return false if steps[0] > MAX_PS_STEPS || stack.length > MAX_PS_STACK
        case op.kind
        when PsOp::NUM
          stack << op.num
          flags << 0
        when PsOp::BOOL
          stack << op.num
          flags << 1
        when PsOp::IF
          return false if stack.empty?
          v = stack.pop
          b = flags.pop
          if b == 1 && v != 0.0
            return false unless run(op.body1, stack, flags, steps)
          end
        when PsOp::IFELSE
          return false if stack.empty?
          v = stack.pop
          b = flags.pop
          body = (b == 1 && v != 0.0) ? op.body1 : op.body2
          return false unless run(body, stack, flags, steps)
        else
          return false unless apply(op.name, stack, flags)
        end
      end
      true
    end

    def self.push(stack, flags, v, isbool)
      stack << v
      flags << isbool
      true
    end

    def self.apply(name, stack, flags)
      case name
      when "abs", "neg", "ceiling", "floor", "round", "truncate", "cvi", "cvr",
           "sqrt", "sin", "cos", "ln", "log", "not"
        return false if stack.empty?
        a = stack.pop
        ab = flags.pop
        case name
        when "abs" then return push(stack, flags, a.abs, 0)
        when "neg" then return push(stack, flags, -a, 0)
        when "ceiling" then return push(stack, flags, a.ceil.to_f, 0)
        when "floor" then return push(stack, flags, a.floor.to_f, 0)
        when "round" then return push(stack, flags, (a + 0.5).floor.to_f, 0)
        when "truncate", "cvi" then return push(stack, flags, a.truncate.to_f, 0)
        when "cvr" then return push(stack, flags, a, 0)
        when "sqrt"
          a = 0.0 if a < 0.0
          return push(stack, flags, Math.sqrt(a), 0)
        when "sin" then return push(stack, flags, Math.sin(a * Math::PI / 180.0), 0)
        when "cos" then return push(stack, flags, Math.cos(a * Math::PI / 180.0), 0)
        when "ln" then return push(stack, flags, Math.log(a), 0)
        when "log" then return push(stack, flags, Math.log10(a), 0)
        else
          # not
          return push(stack, flags, a != 0.0 ? 0.0 : 1.0, 1) if ab == 1
          return push(stack, flags, (~a.to_i).to_f, 0)
        end
      when "add", "sub", "mul", "div", "idiv", "mod", "exp", "atan"
        return false if stack.length < 2
        b = stack.pop
        flags.pop
        a = stack.pop
        flags.pop
        v = 0.0
        case name
        when "add" then v = a + b
        when "sub" then v = a - b
        when "mul" then v = a * b
        when "div" then v = b == 0.0 ? 0.0 : a / b
        when "idiv"
          bi = b.to_i
          v = bi == 0 ? 0.0 : (a.to_i.to_f / bi.to_f).truncate.to_f
        when "mod"
          bi = b.to_i
          ai = a.to_i
          if bi == 0
            v = 0.0
          else
            q = (ai.to_f / bi.to_f).truncate
            v = (ai - q * bi).to_f
          end
        when "exp" then v = a ** b
        else
          deg = Math.atan2(a, b) * 180.0 / Math::PI
          deg += 360.0 if deg < 0.0
          v = deg
        end
        return push(stack, flags, v, 0)
      when "eq", "ne", "gt", "ge", "lt", "le"
        return false if stack.length < 2
        b = stack.pop
        flags.pop
        a = stack.pop
        flags.pop
        r = false
        case name
        when "eq" then r = a == b
        when "ne" then r = a != b
        when "gt" then r = a > b
        when "ge" then r = a >= b
        when "lt" then r = a < b
        else r = a <= b
        end
        return push(stack, flags, r ? 1.0 : 0.0, 1)
      when "and", "or", "xor"
        return false if stack.length < 2
        b = stack.pop
        bb = flags.pop
        a = stack.pop
        ab = flags.pop
        if ab == 1 && bb == 1
          x = a != 0.0
          y = b != 0.0
          r = name == "and" ? (x && y) : (name == "or" ? (x || y) : (x != y))
          return push(stack, flags, r ? 1.0 : 0.0, 1)
        end
        ai = a.to_i
        bi = b.to_i
        v = name == "and" ? (ai & bi) : (name == "or" ? (ai | bi) : (ai ^ bi))
        return push(stack, flags, v.to_f, 0)
      when "bitshift"
        return false if stack.length < 2
        shift = stack.pop.to_i
        flags.pop
        a = stack.pop.to_i
        flags.pop
        v = 0
        if shift >= 0
          v = shift >= 64 ? 0 : a << shift
        else
          s = -shift
          s = 63 if s > 63
          v = a >> s
        end
        return push(stack, flags, v.to_f, 0)
      when "pop"
        return false if stack.empty?
        stack.pop
        flags.pop
        return true
      when "dup"
        return false if stack.empty?
        return push(stack, flags, stack[stack.length - 1], flags[flags.length - 1])
      when "exch"
        return false if stack.length < 2
        n = stack.length
        t = stack[n - 1]
        stack[n - 1] = stack[n - 2]
        stack[n - 2] = t
        f = flags[n - 1]
        flags[n - 1] = flags[n - 2]
        flags[n - 2] = f
        return true
      when "copy"
        return false if stack.empty?
        count = stack.pop.to_i
        flags.pop
        count = 0 if count < 0
        return false if count > stack.length || stack.length + count > MAX_PS_STACK
        start = stack.length - count
        k = 0
        while k < count
          stack << stack[start + k]
          flags << flags[start + k]
          k += 1
        end
        return true
      when "index"
        return false if stack.empty?
        count = stack.pop.to_i
        flags.pop
        count = 0 if count < 0
        at = stack.length - count - 1
        return false if at < 0
        return push(stack, flags, stack[at], flags[at])
      when "roll"
        return false if stack.length < 2
        j = stack.pop.to_i
        flags.pop
        count = stack.pop.to_i
        flags.pop
        count = 0 if count < 0
        return false if count > stack.length
        return true if count == 0
        start = stack.length - count
        shift = j % count
        shift += count if shift < 0
        return true if shift == 0
        tail = []
        tailf = []
        k = 0
        while k < count
          tail << stack[start + k]
          tailf << flags[start + k]
          k += 1
        end
        k = 0
        while k < count
          stack[start + ((k + shift) % count)] = tail[k]
          flags[start + ((k + shift) % count)] = tailf[k]
          k += 1
        end
        return true
      end
      false
    end
  end
end
