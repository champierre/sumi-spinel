# Walks the document and converts every place that can hold color: page
# contents, form XObjects, images, patterns, shadings, Type 3 glyphs,
# annotations and form fields.

module Sumi
  # A dictionary inside an object, reached through direct (non-reference)
  # dictionary keys.
  class DictLoc
    attr_reader :id, :path

    def initialize(id, path)
      @id = id
      @path = path
    end

    def self.object(id) = DictLoc.new(id, [])

    # A string key, because a hash keyed by an object would compare identity.
    def key
      @path.empty? ? @id.to_s : @id.to_s + "/" + @path.join("/")
    end

    def child_path(name)
      p = @path.dup
      p << name
      p
    end
  end

  class SumiError < StandardError; end
  class EncryptedError < SumiError; end
  class InvalidPdfError < SumiError; end
  class LimitExceededError < SumiError; end
  class UnsupportedPdfError < SumiError; end

  class Converter
    attr_reader :doc, :report

    def initialize(doc, settings)
      @doc = doc
      @settings = settings
      @report = Report.new
      @done_streams = {}
      @done_dicts = {}
      @page_contents = {}
      @form_resources = nil
    end

    # ---- dictionary navigation ----------------------------------------

    def dict_at(loc)
      o = @doc.objects[loc.id]
      return nil if o.nil?
      d = o.as_dict
      return nil if d.nil?
      loc.path.each do |k|
        v = d[k]
        return nil if v.nil? || !v.dict?
        d = v.dict
      end
      d
    end

    # The dictionary stored under `key`, following one reference.
    def child(loc, key)
      d = dict_at(loc)
      return nil if d.nil?
      v = d[key]
      return nil if v.nil?
      found = nil
      if v.ref?
        found = DictLoc.object(v.num)
      elsif v.dict?
        found = DictLoc.new(loc.id, loc.child_path(key))
      else
        return nil
      end
      dict_at(found).nil? ? nil : found
    end

    # All dictionaries and streams stored as values of the dictionary at `loc`.
    def children(loc)
      d = dict_at(loc)
      return [] if d.nil?
      keys = d.keys
      out = []
      keys.each do |k|
        c = child(loc, k)
        out << c if c
      end
      out
    end

    def stream?(loc)
      return false unless loc.path.empty?
      o = @doc.objects[loc.id]
      !o.nil? && o.stream?
    end

    # ---- the walk -----------------------------------------------------

    def run
      pages = @doc.pages
      @report.pages = pages.length
      acroform = nil
      root = @doc.trailer["Root"]
      if root && root.ref?
        acroform = child(DictLoc.object(root.num), "AcroForm")
      end
      @form_resources = acroform.nil? ? nil : child(acroform, "DR")

      pages.each { |page| page(page) }
      acroform(acroform) if acroform
    end

    # Turns a per-object problem into a warning, or aborts on a limit.
    def outcome(what, message)
      @report.warn("#{what} not converted: #{message}")
    end

    def page(page_id)
      loc = DictLoc.object(page_id)
      resources = inherited_resources(page_id)

      content_ids = @doc.page_contents(page_id)
      unless content_ids.empty?
        key = content_ids.join(",") + "|" + (resources.nil? ? "-" : resources.key)
        new_id = 0
        if @page_contents.key?(key)
          new_id = @page_contents[key]
        else
          new_id = page_content(loc, content_ids, resources)
          @page_contents[key] = new_id
        end
        if new_id > 0
          d = dict_at(loc)
          d["Contents"] = Obj.ref(new_id, 0) if d
        end
      end

      resources(resources, 0) if resources
      group(loc)

      annots = []
      d = dict_at(loc)
      if d
        a = @doc.dget(d, "Annots")
        if a && a.array?
          a.items.each { |o| annots << o.num if o.ref? }
        end
      end
      annots.each { |a| annotation(DictLoc.object(a)) }
    end

    # /Resources is inherited from the nearest ancestor in the page tree.
    def inherited_resources(page_id)
      node = page_id
      seen = {}
      while !seen.key?(node) && seen.length < 64
        seen[node] = true
        loc = DictLoc.object(node)
        found = child(loc, "Resources")
        return found if found
        d = dict_at(loc)
        return nil if d.nil?
        parent = d["Parent"]
        return nil if parent.nil? || !parent.ref?
        node = parent.num
      end
      nil
    end

    def page_content(page, ids, resources)
      limit = @settings.max_stream_bytes
      data = String.new
      ids.each do |id|
        o = @doc.objects[id]
        next if o.nil? || !o.stream?
        decoded = nil
        begin
          decoded = @doc.decode_stream_obj(o, limit)
        rescue Filters::LimitError => e
          raise LimitExceededError, e.message
        rescue Filters::DecodeError => e
          outcome("page content", e.message)
          return 0
        rescue Filters::UnsupportedError => e
          outcome("page content", e.message)
          return 0
        end
        if data.bytesize + decoded.bytesize > limit
          raise LimitExceededError, "page content is larger than #{limit} bytes"
        end
        data << decoded
        data << "\n"
      end

      pair = rewrite(data, resources, false, "page content")
      return 0 if pair.nil?
      output = pair[0]
      name = pair[1]
      add_pattern_gray(resources, page, name) if output.uses_pattern_gray
      return 0 unless output.changed
      @report.content_streams = @report.content_streams + 1
      @doc.add(Streams.flate_stream({}, output.data))
    end

    # Returns [Output, pattern_gray_name] or nil.
    def rewrite(data, resources, inherited_state, what)
      resource_dict = resources.nil? ? nil : dict_at(resources)
      existing = resource_dict.nil? ? nil : @doc.dget_dict(resource_dict, "ColorSpace")
      name = "SumiPatternGray"
      n = 1
      while existing && existing.key?(name)
        name = "SumiPatternGray#{n}"
        n += 1
      end
      env = Env.new(@doc, resource_dict, @settings, name, inherited_state)
      begin
        output = Rewriter.rewrite(data, env, @report)
        return [output, name]
      rescue Filters::LimitError => e
        raise LimitExceededError, e.message
      rescue Filters::DecodeError => e
        outcome(what, e.message)
        return nil
      rescue Filters::UnsupportedError => e
        outcome(what, e.message)
        return nil
      end
    end

    # Adds `[/Pattern /DeviceGray]` under `name` to the resources.
    def add_pattern_gray(resources, owner, name)
      loc = resources
      if loc.nil?
        d = dict_at(owner)
        return if d.nil?
        d["Resources"] = Obj.dictionary({})
        loc = DictLoc.new(owner.id, owner.child_path("Resources"))
      end
      spaces = child(loc, "ColorSpace")
      if spaces.nil?
        d = dict_at(loc)
        return if d.nil?
        d["ColorSpace"] = Obj.dictionary({})
        spaces = DictLoc.new(loc.id, loc.child_path("ColorSpace"))
      end
      d = dict_at(spaces)
      return if d.nil?
      d[name] = Obj.array([Obj.name("Pattern"), Obj.name("DeviceGray")])
    end

    def resources(loc, depth)
      if depth > @settings.max_depth
        @report.warn("resources nested too deeply were not converted")
        return
      end
      return if @done_dicts.key?(loc.key)
      @done_dicts[loc.key] = true

      xobjects = []
      x = child(loc, "XObject")
      children(x).each { |c| xobjects << c if stream?(c) } if x
      patterns = []
      p = child(loc, "Pattern")
      patterns = children(p) if p
      shadings = []
      s = child(loc, "Shading")
      shadings = children(s) if s
      fonts = []
      f = child(loc, "Font")
      fonts = children(f) if f

      xobjects.each do |xobject|
        d = dict_at(xobject)
        subtype = d.nil? ? nil : @doc.dget_name(d, "Subtype")
        if subtype == "Image"
          unless @done_streams.key?(xobject.id)
            @done_streams[xobject.id] = true
            begin
              Image.convert_xobject(@doc, xobject.id, @settings, @report)
            rescue Filters::LimitError => e
              raise LimitExceededError, e.message
            rescue Filters::DecodeError => e
              outcome("image", e.message)
            rescue Filters::UnsupportedError => e
              outcome("image", e.message)
            end
          end
        elsif subtype == "Form"
          content_stream(xobject.id, loc, depth + 1, "form XObject")
        end
      end

      patterns.each do |pattern|
        next if @done_dicts.key?(pattern.key)
        @done_dicts[pattern.key] = true
        d = dict_at(pattern)
        ptype = d.nil? ? nil : @doc.dget_int(d, "PatternType")
        if ptype == 1 && stream?(pattern)
          content_stream(pattern.id, loc, depth + 1, "tiling pattern")
        elsif ptype == 2
          sh = child(pattern, "Shading")
          shading(sh) if sh
        end
      end

      shadings.each { |sh| shading(sh) }

      fonts.each do |font|
        d = dict_at(font)
        next if d.nil?
        next unless @doc.dget_name(d, "Subtype") == "Type3"
        glyph_resources = child(font, "Resources")
        glyph_resources = loc if glyph_resources.nil?
        procs = child(font, "CharProcs")
        next if procs.nil?
        children(procs).each do |glyph|
          next unless stream?(glyph)
          content_stream(glyph.id, glyph_resources, depth + 1, "Type 3 glyph")
        end
      end
    end

    # A form XObject, tiling pattern, glyph or appearance stream.
    def content_stream(id, fallback, depth, what)
      return if @done_streams.key?(id)
      @done_streams[id] = true
      loc = DictLoc.object(id)
      res = child(loc, "Resources")
      res = fallback if res.nil?
      o = @doc.objects[id]
      return unless o && o.stream?
      data = nil
      begin
        data = @doc.decode_stream_obj(o, @settings.max_stream_bytes)
      rescue Filters::LimitError => e
        raise LimitExceededError, e.message
      rescue Filters::DecodeError => e
        outcome(what, e.message)
      rescue Filters::UnsupportedError => e
        outcome(what, e.message)
      end
      if data
        pair = rewrite(data, res, true, what)
        if pair
          output = pair[0]
          name = pair[1]
          if output.changed
            target = @doc.objects[id]
            if target && target.stream?
              Streams.set_flate_content(target, output.data)
              @report.content_streams = @report.content_streams + 1
            end
          end
          add_pattern_gray(res, loc, name) if output.uses_pattern_gray
        end
      end
      group(loc)
      res2 = child(loc, "Resources")
      res2 = res if res2.nil?
      resources(res2, depth) if res2
    end

    def shading(loc)
      return if @done_dicts.key?(loc.key)
      @done_dicts[loc.key] = true
      d = dict_at(loc)
      return if d.nil?
      plan = nil
      begin
        plan = Shading.plan(@doc, d, @settings)
      rescue Filters::LimitError => e
        raise LimitExceededError, e.message
      rescue Filters::DecodeError => e
        outcome("shading", e.message)
        return
      rescue Filters::UnsupportedError => e
        outcome("shading", e.message)
        return
      end
      return if plan.nil?
      function_id = @doc.add(plan.function)
      d = dict_at(loc)
      return if d.nil?
      d["ColorSpace"] = Obj.name("DeviceGray")
      d["Function"] = Obj.ref(function_id, 0)
      if plan.background
        d["Background"] = plan.background
      else
        d.delete("Background")
      end
      @report.shadings = @report.shadings + 1
    end

    # Transparency groups blend in their own color space; make it gray too.
    def group(owner)
      g = child(owner, "Group")
      return if g.nil?
      d = dict_at(g)
      return if d.nil?
      cs = d["CS"]
      return if cs.nil?
      space = ColorSpace.resolve(@doc, cs, nil, @settings.max_stream_bytes)
      return unless space.convertible? && !space.gray?
      d = dict_at(g)
      d["CS"] = Obj.name("DeviceGray") if d
    end

    def annotation(loc)
      return if @done_dicts.key?(loc.key)
      @done_dicts[loc.key] = true
      appearance = child(loc, "AP")
      if appearance
        ["N", "R", "D"].each do |key|
          state = child(appearance, key)
          next if state.nil?
          streams = []
          if stream?(state)
            streams << state
          else
            children(state).each { |s| streams << s if stream?(s) }
          end
          streams.each { |s| content_stream(s.id, nil, 1, "annotation appearance") }
        end
      end
      color_array(loc, "C")
      color_array(loc, "IC")
      mk = child(loc, "MK")
      if mk
        color_array(mk, "BG")
        color_array(mk, "BC")
      end
      default_appearance(loc)
    end

    def acroform(loc)
      default_appearance(loc)
      resources(@form_resources, 0) if @form_resources
      stack = []
      d = dict_at(loc)
      if d
        f = @doc.dget(d, "Fields")
        if f && f.array?
          f.items.each { |o| stack << [o.num, 0] if o.ref? }
        end
      end
      while !stack.empty?
        entry = stack.pop
        id = entry[0]
        depth = entry[1]
        fl = DictLoc.object(id)
        next if depth > @settings.max_depth || @done_dicts.key?(fl.key)
        kids = []
        fd = dict_at(fl)
        if fd
          k = @doc.dget(fd, "Kids")
          if k && k.array?
            k.items.each { |o| kids << o.num if o.ref? }
          end
        end
        annotation(fl)
        kids.each { |kid| stack << [kid, depth + 1] }
      end
    end

    # Annotation colors such as /C [1 0 0].
    def color_array(loc, key)
      tone = @settings.tone
      d = dict_at(loc)
      return if d.nil?
      v = d[key]
      return if v.nil? || !v.array?
      values = []
      ok = true
      v.items.each do |o|
        if o.number?
          values << o.to_f
        else
          ok = false
        end
      end
      return unless ok
      space = nil
      space = ColorSpace.simple(ColorSpace::GRAY) if values.length == 1 && tone.monochrome?
      space = ColorSpace.simple(ColorSpace::RGB) if values.length == 3
      space = ColorSpace.simple(ColorSpace::CMYK) if values.length == 4
      return if space.nil?
      g = space.to_gray(values, @settings.gray_model)
      gray = tone.apply(g.nil? ? 0.0 : g)
      d = dict_at(loc)
      d[key] = Obj.array([Obj.real(gray)]) if d
    end

    # Default appearance strings (/DA) hold operators such as `1 0 0 rg`.
    def default_appearance(loc)
      d = dict_at(loc)
      return if d.nil?
      da = d["DA"]
      return if da.nil? || !da.str?
      text = da.str
      pair = rewrite(text, @form_resources, false, "default appearance")
      return if pair.nil?
      output = pair[0]
      return unless output.changed && !output.uses_pattern_gray
      d = dict_at(loc)
      d["DA"] = Obj.string(output.data, false) if d
    end
  end

  # ---- the entry points ------------------------------------------------

  module Convert
    def self.convert_bytes(input, settings)
      head = input.byteslice(0, input.bytesize < 1024 ? input.bytesize : 1024)
      unless Bytes.include?(head, "%PDF-")
        raise InvalidPdfError, "invalid PDF: missing %PDF- header"
      end
      doc = Document.load(input)
      raise EncryptedError, "encrypted PDFs are not supported" if doc.encrypted
      raise InvalidPdfError, "invalid PDF: the document has no pages" if doc.pages.empty?
      dropped = unreadable_objects(doc)

      converter = Converter.new(doc, settings)
      converter.run
      report = converter.report
      if doc.repaired_xref
        report.warn("the cross-reference table could not be read; " \
                    "the file was rebuilt from the objects found in it")
      elsif doc.repaired_objects > 0
        n = doc.repaired_objects
        report.warn("the cross-reference table pointed at #{n} object(s) that " \
                    "were not there; they were found by scanning the file")
      end
      dropped.each { |w| report.warn(w) }
      [Writer.save(doc), report]
    end

    # Objects that are referenced and declared in the file but could not be
    # parsed. A page that needs one is a hard error; the rest are warnings.
    def self.unreadable_objects(doc)
      refs = {}
      doc.objects.each { |_, o| collect(o, refs) }
      doc.trailer.each { |_, o| collect(o, refs) }
      missing = []
      refs.each do |num, _|
        missing << num unless doc.objects.key?(num)
      end
      unreadable = []
      missing.each { |num| unreadable << num if doc.declared.key?(num) }
      return [] if unreadable.empty?
      bad = {}
      unreadable.each { |num| bad[num] = true }

      # Everything a page draws is reachable from /Contents, /Resources and
      # /Annots; /Parent and /P point back up the tree and are not followed.
      stack = []
      doc.pages.each do |page|
        node = page
        depth = 0
        seen = {}
        while node > 0 && depth < 64 && !seen.key?(node)
          seen[node] = true
          o = doc.objects[node]
          break if o.nil?
          d = o.as_dict
          break if d.nil?
          keys = depth == 0 ? ["Contents", "Resources", "Annots"] : ["Resources"]
          keys.each do |k|
            v = d[k]
            stack << v if v
          end
          parent = d["Parent"]
          node = parent && parent.ref? ? parent.num : 0
          depth += 1
        end
      end
      visited = {}
      while !stack.empty?
        o = stack.pop
        next if o.nil?
        if o.ref?
          if bad.key?(o.num)
            raise InvalidPdfError,
                  "invalid PDF: object #{o.num} used by a page could not be read"
          end
          next if visited.key?(o.num)
          visited[o.num] = true
          target = doc.objects[o.num]
          stack << target if target
        elsif o.array?
          o.items.each { |it| stack << it }
        elsif o.dict? || o.stream?
          o.dict.each do |k, v|
            stack << v unless k == "Parent" || k == "P"
          end
        end
      end
      out = []
      unreadable.sort.each do |num|
        out << "object #{num} could not be read and was dropped"
      end
      out
    end

    def self.collect(obj, refs)
      return if obj.nil?
      if obj.ref?
        refs[obj.num] = true
      elsif obj.array?
        obj.items.each { |o| collect(o, refs) }
      elsif obj.dict? || obj.stream?
        obj.dict.each { |_, v| collect(v, refs) } if obj.dict
      end
    end
  end
end
