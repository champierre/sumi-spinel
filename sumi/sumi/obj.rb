# PDF object model.
#
# Every PDF value is one Obj carrying a `kind` tag and the field that kind uses.
# One class instead of a class per kind keeps arrays and hashes of objects
# monomorphic, which is what Spinel's whole-program inference wants.

module Sumi
  class Obj
    NULL   = 0
    BOOL   = 1
    INT    = 2
    REAL   = 3
    STR    = 4
    NAME   = 5
    ARRAY  = 6
    DICT   = 7
    STREAM = 8
    REF    = 9

    attr_accessor :kind, :num, :real, :str, :items, :dict, :raw, :gen, :hex
    # Streams read from the file keep their bytes as stored; `raw` is encoded
    # with whatever /Filter says. `allow_compress` is false for streams that
    # must stay as they are (the writer's own object streams set their filter).
    attr_accessor :allow_compress

    def initialize(kind)
      @kind = kind
      @num = 0
      @real = 0.0
      @str = nil
      @items = nil
      @dict = nil
      @raw = nil
      @gen = 0
      @hex = false
      @allow_compress = true
    end

    def self.null = Obj.new(NULL)

    def self.bool(v)
      o = Obj.new(BOOL)
      o.num = v ? 1 : 0
      o
    end

    def self.int(v)
      o = Obj.new(INT)
      o.num = v
      o
    end

    def self.real(v)
      o = Obj.new(REAL)
      o.real = v
      o
    end

    def self.string(bytes, hex = false)
      o = Obj.new(STR)
      o.str = bytes
      o.hex = hex
      o
    end

    def self.name(text)
      o = Obj.new(NAME)
      o.str = text
      o
    end

    def self.array(list)
      o = Obj.new(ARRAY)
      o.items = list
      o
    end

    def self.dictionary(d)
      o = Obj.new(DICT)
      o.dict = d
      o
    end

    def self.stream(d, raw)
      o = Obj.new(STREAM)
      o.dict = d
      o.raw = raw
      o
    end

    def self.ref(id, gen = 0)
      o = Obj.new(REF)
      o.num = id
      o.gen = gen
      o
    end

    def null? = @kind == NULL
    def bool? = @kind == BOOL
    def int? = @kind == INT
    def real? = @kind == REAL
    def number? = @kind == INT || @kind == REAL
    def str? = @kind == STR
    def name? = @kind == NAME
    def array? = @kind == ARRAY
    def dict? = @kind == DICT
    def stream? = @kind == STREAM
    def ref? = @kind == REF

    def truthy? = @kind == BOOL && @num != 0

    # The numeric value of an integer or real object; 0.0 for anything else.
    def to_f
      return @real if @kind == REAL
      return @num.to_f if @kind == INT
      0.0
    end

    def to_i
      return @real.to_i if @kind == REAL
      return @num if @kind == INT
      0
    end

    # The dictionary of a dictionary or a stream.
    def as_dict
      return @dict if @kind == DICT || @kind == STREAM
      nil
    end

    def name_text
      return @str if @kind == NAME
      nil
    end
  end
end
