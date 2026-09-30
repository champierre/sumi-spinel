module Sumi
  # A growable byte buffer.
  #
  # Serialization hands the buffer down through recursive calls, and a plain
  # mutable String passed that way is copied at each frame (Spinel 2026.09.12:
  # the appends of a directly self-recursive callee are lost outright). Holding
  # the bytes in an object's ivar keeps one buffer for the whole walk.
  class Buf
    def initialize
      @s = String.new
      # CRuby tags a fresh String ASCII-8BIT and refuses to append a UTF-8
      # string holding non-ASCII bytes; Spinel has one representation and the
      # branch is dropped at compile time.
      @s.force_encoding("BINARY") unless RUBY_ENGINE == "spinel"
    end

    def <<(bytes)
      if RUBY_ENGINE == "spinel"
        @s << bytes
      else
        @s << bytes.b
      end
      self
    end

    def bytesize = @s.bytesize
    def to_s = @s
  end
end

module Sumi
  # Byte-offset searching.
  #
  # `String#index` counts characters, so on a string that is not tagged binary
  # it answers a character offset where the PDF parser needs a byte one. These
  # scan bytes and never depend on how the string is tagged.
  module Bytes
    # The first byte offset of `needle` at or after `from`, or -1.
    def self.index(data, needle, from)
      n = needle.bytesize
      return from if n == 0
      last = data.bytesize - n
      first = needle.getbyte(0)
      i = from < 0 ? 0 : from
      while i <= last
        if data.getbyte(i) == first
          k = 1
          k += 1 while k < n && data.getbyte(i + k) == needle.getbyte(k)
          return i if k == n
        end
        i += 1
      end
      -1
    end

    # The last byte offset of `needle` at or before `before`, or -1.
    # `before` of -1 means the end of the string.
    def self.rindex(data, needle, before)
      n = needle.bytesize
      last = data.bytesize - n
      start = before < 0 ? last : (before < last ? before : last)
      return start if n == 0
      first = needle.getbyte(0)
      i = start
      while i >= 0
        if data.getbyte(i) == first
          k = 1
          k += 1 while k < n && data.getbyte(i + k) == needle.getbyte(k)
          return i if k == n
        end
        i -= 1
      end
      -1
    end

    def self.include?(data, needle)
      index(data, needle, 0) >= 0
    end

    # Whether `data` holds `needle` at `at`.
    def self.match?(data, at, needle)
      n = needle.bytesize
      return false if at < 0 || at + n > data.bytesize
      i = 0
      while i < n
        return false unless data.getbyte(at + i) == needle.getbyte(i)
        i += 1
      end
      true
    end
  end
end
