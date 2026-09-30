# DEFLATE through the system zlib.
#
# The Rust version links flate2, so the port links libz: the comparison is then
# between the two programs rather than between two DEFLATE implementations.
#
# Buffers live on the C side and the results come back as `:binstr`, whose byte
# count rides `sp_ffi_bin_len`, so nothing here depends on an `IO::Buffer`
# surviving a collection.

# CRuby runs the same library through its own zlib, so `spin test` can use it as
# the oracle for the compiled program.
if RUBY_ENGINE == "spinel"
  module Sumi
    module Zl
      ffi_lib "z"
      ffi_source <<~C
        #include <zlib.h>
        #include <string.h>
        #include <stdlib.h>

        /* The binary-safe return contract: the callee sets the byte count. */
        extern SP_TLS int sp_ffi_bin_len;

        static unsigned char *sumi_zbuf = NULL;
        static size_t sumi_zcap = 0;

        static int sumi_zreserve(size_t need) {
          if (need <= sumi_zcap) return 1;
          size_t cap = sumi_zcap ? sumi_zcap : 65536;
          while (cap < need) cap *= 2;
          unsigned char *grown = (unsigned char *)realloc(sumi_zbuf, cap);
          if (!grown) return 0;
          sumi_zbuf = grown;
          sumi_zcap = cap;
          return 1;
        }

        const char *sumi_deflate(const char *src, long n, int level) {
          sp_ffi_bin_len = 0;
          uLong bound = compressBound((uLong)n);
          if (!sumi_zreserve((size_t)bound)) return NULL;
          uLongf out = (uLongf)bound;
          if (compress2(sumi_zbuf, &out, (const Bytef *)src, (uLong)n, level) != Z_OK) {
            return NULL;
          }
          sp_ffi_bin_len = (int)out;
          return (const char *)sumi_zbuf;
        }

        /* Inflates the whole stream, growing the buffer as needed. `raw` selects
           raw DEFLATE (no zlib header), which is the fallback for broken streams.
           A stream that ends early still yields what it produced, as viewers
           accept; a stream that yields nothing returns NULL. */
        const char *sumi_inflate(const char *src, long n, long limit) {
          sp_ffi_bin_len = 0;
          z_stream s;
          size_t cap = (size_t)n * 4;
          if (cap < 65536) cap = 65536;
          if (!sumi_zreserve(cap)) return NULL;
          memset(&s, 0, sizeof(s));
          s.next_in = (Bytef *)src;
          s.avail_in = (uInt)n;
          if (inflateInit2(&s, 47) != Z_OK) return NULL;
          size_t produced = 0;
          int rc = Z_OK;
          while (1) {
            s.next_out = sumi_zbuf + produced;
            s.avail_out = (uInt)(sumi_zcap - produced);
            rc = inflate(&s, Z_NO_FLUSH);
            produced = sumi_zcap - s.avail_out;
            if (rc == Z_STREAM_END || rc == Z_NEED_DICT) break;
            if (rc != Z_OK && rc != Z_BUF_ERROR) break;
            if (s.avail_out == 0) {
              if ((long)produced > limit) { rc = Z_MEM_ERROR; break; }
              if (!sumi_zreserve(sumi_zcap * 2)) { rc = Z_MEM_ERROR; break; }
              continue;
            }
            if (rc == Z_BUF_ERROR || s.avail_in == 0) break;
          }
          inflateEnd(&s);
          if (rc == Z_MEM_ERROR) return NULL;
          if (produced == 0) return NULL;
          sp_ffi_bin_len = (int)produced;
          return (const char *)sumi_zbuf;
        }

        /* Raw DEFLATE, for a stream whose zlib header is missing or damaged. */
        const char *sumi_inflate_raw(const char *src, long n, long limit) {
          sp_ffi_bin_len = 0;
          z_stream s;
          size_t cap = (size_t)n * 4;
          if (cap < 65536) cap = 65536;
          if (!sumi_zreserve(cap)) return NULL;
          memset(&s, 0, sizeof(s));
          s.next_in = (Bytef *)src;
          s.avail_in = (uInt)n;
          if (inflateInit2(&s, -15) != Z_OK) return NULL;
          size_t produced = 0;
          int rc = Z_OK;
          while (1) {
            s.next_out = sumi_zbuf + produced;
            s.avail_out = (uInt)(sumi_zcap - produced);
            rc = inflate(&s, Z_NO_FLUSH);
            produced = sumi_zcap - s.avail_out;
            if (rc == Z_STREAM_END || rc == Z_NEED_DICT) break;
            if (rc != Z_OK && rc != Z_BUF_ERROR) break;
            if (s.avail_out == 0) {
              if ((long)produced > limit) { rc = Z_MEM_ERROR; break; }
              if (!sumi_zreserve(sumi_zcap * 2)) { rc = Z_MEM_ERROR; break; }
              continue;
            }
            if (rc == Z_BUF_ERROR || s.avail_in == 0) break;
          }
          inflateEnd(&s);
          if (rc == Z_MEM_ERROR) return NULL;
          if (produced == 0) return NULL;
          sp_ffi_bin_len = (int)produced;
          return (const char *)sumi_zbuf;
        }
      C
      ffi_func :sumi_deflate, [:str, :long, :int], :binstr
      ffi_func :sumi_inflate, [:str, :long, :long], :binstr
      ffi_func :sumi_inflate_raw, [:str, :long, :long], :binstr
    end

    module Flate
      LIMIT = 1 << 31

      def self.compress(data, level)
        n = data.bytesize
        return "" if n == 0
        out = Zl.sumi_deflate(data, n, level)
        raise Filters::DecodeError, "deflate failed" if out.nil?
        out
      end

      def self.decompress(data, raw)
        n = data.bytesize
        return "" if n == 0
        raw == 1 ? Zl.sumi_inflate_raw(data, n, LIMIT) : Zl.sumi_inflate(data, n, LIMIT)
      end
    end
  end
else
  require "zlib"

  module Sumi
    module Flate
      def self.compress(data, level)
        Zlib.deflate(data, level)
      end

      def self.decompress(data, raw)
        z = Zlib::Inflate.new(raw == 1 ? -Zlib::MAX_WBITS : Zlib::MAX_WBITS)
        out = nil
        begin
          out = z.inflate(data)
        rescue Zlib::Error
          out = nil
        end
        return nil if out.nil? || out.bytesize == 0
        out
      end
    end
  end
end
