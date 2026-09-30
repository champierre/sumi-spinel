# Command line tool: convert PDF colors to grayscale or monochrome.

require "sumi"

VERSION = "0.2.0"

USAGE = <<~TEXT
  Convert the colors of a PDF to grayscale or monochrome, keeping text and vector graphics.

  Usage: sumi <INPUT> -o <OUTPUT> [OPTIONS]

  Arguments:
    <INPUT>  Input PDF file, or `-` for standard input

  Options:
    -o, --output <OUTPUT>       Output PDF file, or `-` for standard output
        --mode <MODE>           grayscale (default) or monochrome
        --gray-model <MODEL>    luma (default) or colorimetric
        --threshold <T>         Gray level (0.0-1.0) for monochrome [default: 0.5]
        --dither                Dither images instead of thresholding them
        --strict                Fail instead of leaving unsupported parts unchanged
        --overwrite             Replace the output file if it already exists
        --timeout <SECONDS>     Abort when the conversion takes longer
    -v, --verbose               Print conversion statistics
        --report <FORMAT>       Print a machine-readable report (json)
    -h, --help                  Print help
    -V, --version               Print version

  Exit codes:
    0  success
    1  generic error
    2  invalid arguments
    3  invalid PDF
    4  unsupported PDF feature (encrypted PDF, or --strict found unconverted parts)
    5  I/O error
    6  timeout
TEXT

# Set once the report format is known; `die` then prints JSON instead.
$report_json = false
$report_mode = "grayscale"
$report_gray_model = "luma"

def die(code, message, kind = "internal")
  if $report_json
    $stderr.puts json_report(nil, $report_mode, $report_gray_model, code, kind, message, [])
  else
    $stderr.puts "sumi: #{message}"
  end
  exit code
end

input = nil
output = nil
mode = "grayscale"
gray_model = "luma"
threshold = 0.5
dither = false
strict = false
overwrite = false
verbose = false
report_json = false
timeout = 0

i = 0
while i < ARGV.length
  arg = ARGV[i]
  case arg
  when "-h", "--help"
    puts USAGE
    exit 0
  when "-V", "--version"
    puts "sumi #{VERSION}"
    exit 0
  when "-o", "--output"
    i += 1
    output = ARGV[i]
  when "--mode"
    i += 1
    mode = ARGV[i]
  when "--gray-model"
    i += 1
    gray_model = ARGV[i]
  when "--threshold"
    i += 1
    threshold = ARGV[i].to_f
  when "--dither" then dither = true
  when "--strict" then strict = true
  when "--overwrite" then overwrite = true
  when "-v", "--verbose" then verbose = true
  when "--report"
    i += 1
    report_json = ARGV[i] == "json"
  when "--timeout"
    i += 1
    timeout = ARGV[i].to_i
  else
    if arg.start_with?("--output=")
      output = arg.byteslice(9, arg.bytesize - 9)
    elsif arg.start_with?("--mode=")
      mode = arg.byteslice(7, arg.bytesize - 7)
    elsif arg.start_with?("--gray-model=")
      gray_model = arg.byteslice(13, arg.bytesize - 13)
    elsif arg.start_with?("--threshold=")
      threshold = arg.byteslice(12, arg.bytesize - 12).to_f
    elsif arg != "-" && arg.start_with?("-")
      die(2, "unexpected argument `#{arg}`", "invalid_arguments")
    elsif input.nil?
      input = arg
    else
      die(2, "unexpected argument `#{arg}`", "invalid_arguments")
    end
  end
  i += 1
end

die(2, "the following required arguments were not provided: <INPUT>", "invalid_arguments") if input.nil?
die(2, "the following required arguments were not provided: --output <OUTPUT>", "invalid_arguments") if output.nil?
unless mode == "grayscale" || mode == "gray" || mode == "monochrome" || mode == "mono"
  die(2, "unknown mode `#{mode}` (expected grayscale or monochrome)", "invalid_arguments")
end
unless gray_model == "luma" || gray_model == "colorimetric"
  die(2, "unknown gray model `#{gray_model}` (expected luma or colorimetric)", "invalid_arguments")
end
if threshold < 0.0 || threshold > 1.0
  die(2, "threshold must be between 0.0 and 1.0, got #{threshold}", "invalid_arguments")
end

$report_json = report_json
$report_mode = mode
$report_gray_model = gray_model

if output != "-"
  if File.exist?(output) && !overwrite
    die(2, "#{output} already exists (use --overwrite to replace it)", "invalid_arguments")
  end
  if input != "-" && File.exist?(input) &&
     File.expand_path(input) == File.expand_path(output)
    die(2, "input and output must be different files", "invalid_arguments")
  end
end

data = nil
if input == "-"
  $stdin.binmode
  data = $stdin.read
else
  begin
    data = File.binread(input)
  rescue StandardError => e
    die(5, "cannot read #{input}: #{e.message}", "io")
  end
end

settings = Sumi::Settings.new
settings.tone = Sumi::Tone.new(
  (mode == "monochrome" || mode == "mono") ? Sumi::MODE_MONOCHROME : Sumi::MODE_GRAYSCALE,
  threshold
)
settings.gray_model = gray_model == "colorimetric" ? Sumi::GRAY_COLORIMETRIC : Sumi::GRAY_LUMA
settings.dither = dither
settings.strict = strict

if timeout > 0
  seconds = timeout
  Thread.new do
    sleep seconds
    die(6, "timed out after #{seconds} seconds", "timeout")
  end
end

pdf = nil
report = nil
begin
  pair = Sumi::Convert.convert_bytes(data, settings)
  pdf = pair[0]
  report = pair[1]
rescue Sumi::EncryptedError => e
  die(4, e.message, "encrypted_pdf")
rescue Sumi::InvalidPdfError => e
  die(3, e.message, "invalid_pdf")
rescue Sumi::LimitExceededError => e
  die(1, "resource limit exceeded: #{e.message}", "limit_exceeded")
rescue Sumi::SumiError => e
  die(1, e.message)
end

# ---- the machine-readable report -------------------------------------
#
# The same schema the Rust CLI prints: every key is always present, `null` or
# an empty array where it does not apply.

def json_string(value)
  out = String.new
  i = 0
  while i < value.bytesize
    c = value.getbyte(i)
    if c == 0x22
      out << "\\\""
    elsif c == 0x5c
      out << "\\\\"
    elsif c == 0x0a
      out << "\\n"
    elsif c == 0x0d
      out << "\\r"
    elsif c == 0x09
      out << "\\t"
    elsif c < 0x20
      out << "\\u00" << "0123456789abcdef".byteslice((c >> 4) & 0xf, 1) <<
             "0123456789abcdef".byteslice(c & 0xf, 1)
    else
      out << c.chr
    end
    i += 1
  end
  "\"" + out + "\""
end

def json_report(report, mode, gray_model, exit_code, kind, message, details)
  out = String.new
  out << "{\"status\":" << json_string(kind.nil? ? "ok" : "error")
  out << ",\"exit_code\":" << exit_code.to_s
  out << ",\"mode\":" << json_string(mode)
  out << ",\"gray_model\":" << json_string(gray_model)
  out << ",\"report\":"
  if report.nil?
    out << "null"
  else
    warnings = []
    report.warnings.each do |w|
      warnings << "{\"message\":" + json_string(w) + ",\"count\":" + report.counts[w].to_s + "}"
    end
    out << "{\"pages\":" << report.pages.to_s
    out << ",\"content_streams\":" << report.content_streams.to_s
    out << ",\"color_operators\":" << report.color_operators.to_s
    out << ",\"images\":" << report.images.to_s
    out << ",\"shadings\":" << report.shadings.to_s
    out << ",\"warnings\":[" << warnings.join(",") << "]}"
  end
  out << ",\"error\":"
  if kind.nil?
    out << "null"
  else
    items = []
    details.each { |d| items << json_string(d) }
    out << "{\"kind\":" << json_string(kind)
    out << ",\"message\":" << json_string(message)
    out << ",\"details\":[" << items.join(",") << "]}"
  end
  out << "}"
  out
end

if strict && !report.warnings.empty?
  message = "unsupported PDF features: " + report.warnings.join("; ")
  if report_json
    $stderr.puts json_report(nil, mode, gray_model, 4, "unsupported", message,
                             report.warnings)
  else
    $stderr.puts "sumi: #{message}"
  end
  exit 4
end

if report_json
  $stderr.puts json_report(report, mode, gray_model, 0, nil, "", [])
else
  report.warnings.each do |w|
    n = report.counts[w]
    suffix = n > 1 ? " (#{n} times)" : ""
    $stderr.puts "sumi: warning: #{w}#{suffix}"
  end
  if verbose
    $stderr.puts "sumi: #{report.pages} pages, #{report.content_streams} content streams, " \
      "#{report.color_operators} color operators, #{report.images} images, " \
      "#{report.shadings} shadings converted to #{mode}"
  end
end

if output == "-"
  $stdout.write(pdf)
  $stdout.flush
else
  temp = File.join(File.dirname(output), "." + File.basename(output) + ".sumi-#{Process.pid}.tmp")
  begin
    File.binwrite(temp, pdf)
    File.rename(temp, output)
  rescue StandardError => e
    begin
      File.delete(temp)
    rescue StandardError
      nil
    end
    die(5, "cannot write #{output}: #{e.message}", "io")
  end
end
