# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "package"

# Runs a command with a completely replaced environment, retains bounded streams,
# prints its exact receipt, and requires the expected exit. Raises on mismatch.
def checked_command(environment, argv, directory, expected: 0, pattern: nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3(environment, *argv, chdir: directory, unsetenv_others: true)
  receipt = {"argv" => argv, "cwd" => directory, "exit" => status.exitstatus,
             "signal" => status.termsig, "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
             "stdout" => stdout.byteslice(0, 65_536), "stderr" => stderr.byteslice(0, 65_536),
             "truncated" => stdout.bytesize > 65_536 || stderr.bytesize > 65_536}
  puts JSON.generate(receipt)
  raise "Unexpected command outcome" unless status.exitstatus == expected &&
    (!pattern || (stdout + stderr).match?(pattern)) && !receipt.fetch("truncated")
  stdout
end

abort "Usage: ruby script/package_smoke.rb ARCHIVE.tar INVENTORY.json DEVELOPMENT_ROOT PIPELINE_ROOT PRIVATE_ROOT [OTHER_ROOT...]" unless ARGV.length >= 5
archive, inventory_path, *denied = ARGV.map { |name| File.expand_path(name) }
reviewed = JSON.parse(File.binread(inventory_path))
abort "Archive digest differs" unless reviewed.fetch("sha256") == Digest::SHA256.file(archive).hexdigest
records = reviewed.fetch("files")
abort "Duplicate inventory paths" unless records.map { |record| record.fetch("path") }.uniq.length == records.length
denied = denied.map { |name| File.exist?(name) ? File.realpath(name) : name }.uniq
source_root = File.realpath(File.expand_path("..", __dir__))
abort "Development root must include the invoking source" unless denied.any? { |name| source_root == name || source_root.start_with?(name + "/") }
world = Dir.mktmpdir("af-evidence-package-", File.realpath(Dir.tmpdir))
puts JSON.generate("scratch" => world, "denied_read_roots" => denied)
abort "Scratch overlaps a denied root" if denied.any? { |name| world == name || world.start_with?(name + "/") }
unpacked = File.join(world, "package")
Dir.mkdir(unpacked)
seen = []
File.open(archive, "rb") do |stream|
  Gem::Package::TarReader.new(stream) do |tar|
    tar.each do |entry|
      name = entry.full_name
      record = records.find { |item| item.fetch("path") == name }
      unless record && !seen.include?(name) && entry.file? &&
             name.match?(%r{\A[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*\z}) &&
             name.split("/").none? { |part| %w[. .. .git].include?(part) }
        raise "Unsafe or unreviewed archive member: #{name}"
      end
      bytes = entry.read
      raise "Archive member differs: #{name}" unless record.fetch("size") == bytes.bytesize &&
        record.fetch("mode") == entry.header.mode && [0o644, 0o755].include?(entry.header.mode) &&
        record.fetch("sha256") == Digest::SHA256.hexdigest(bytes)
      target = File.join(unpacked, name)
      FileUtils.mkdir_p(File.dirname(target))
      File.open(target, File::WRONLY | File::CREAT | File::EXCL, entry.header.mode) { |output| output.write(bytes) }
      File.chmod(entry.header.mode, target)
      seen << name
    end
  end
end
raise "Unpacked inventory differs" unless seen == SourcePackage.names(unpacked) &&
  seen.sort == records.map { |record| record.fetch("path") }.sort
puts JSON.generate("package_inventory" => "pass", "file_count" => seen.length)

# Construction refusals run without runtime gems, each against a separate copy.
{"missing" => :missing, "symlink" => :symlink, "escape" => :escape}.each do |label, variant|
  copy = File.join(world, label)
  FileUtils.cp_r(unpacked, copy)
  selected = File.join(copy, "lib/af_evidence/error.rb")
  if variant == :escape
    File.open(File.join(copy, "Manifest.txt"), "a") { |output| output.puts "../private" }
  else
    File.unlink(selected)
    File.symlink(File.join(unpacked, "lib/af_evidence/error.rb"), selected) if variant == :symlink
  end
  output = File.join(world, "#{label}.tar")
  begin
    SourcePackage.build(copy, output)
    raise "Construction accepted #{label} input"
  rescue ArgumentError, Errno::ENOENT
    raise "Construction retained incomplete output" if File.exist?(output)
    puts JSON.generate("construction_refusal" => label, "status" => "pass")
  end
end

environment = {"HOME" => File.join(world, "home"), "TMPDIR" => world,
               "PATH" => [File.dirname(RbConfig.ruby), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].join(":"),
               "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR), "GEM_HOME" => Gem.dir,
               "BUNDLE_GEMFILE" => File.join(unpacked, "Gemfile"), "BUNDLE_FROZEN" => "true",
               "BUNDLE_IGNORE_CONFIG" => "true", "MT_NO_PLUGINS" => "1"}
Dir.mkdir(environment.fetch("HOME"))
zstd = ENV.fetch("AF_EVIDENCE_ZSTD", "zstd")
environment["AF_EVIDENCE_ZSTD"] = zstd
checked_command(environment, [RbConfig.ruby, "-S", "bundle", "check"], unpacked)
checked_command(environment, [zstd, "--version"], unpacked)
abort "Isolated smoke requires macOS sandbox-exec; other platforms are unqualified" unless RUBY_PLATFORM.include?("darwin")
profile = "(version 1)(allow default)(deny network*)(deny file-write*)" +
  "(allow file-write* (subpath #{world.to_json}) (literal \"/dev/null\"))" +
  denied.map { |name| "(deny file-read* (subpath #{name.to_json}))" }.join
sandbox = ["/usr/bin/sandbox-exec", "-p", profile]
# Probe an existing development file: a profile that does not actually deny it
# cannot qualify the journey. No source bytes are read into a receipt.
probe = "begin; File.binread(ARGV.fetch(0)); abort 'root still readable'; rescue Errno::EPERM, Errno::EACCES; puts 'root denied'; end"
checked_command(environment, sandbox + [RbConfig.ruby, "-e", probe, File.join(source_root, "Manifest.txt")],
  unpacked, pattern: /root denied/)
example = [RbConfig.ruby, "-rbundler/setup", "-Ilib", "examples/first_store.rb"]
checked_command(environment.merge("BUNDLE_WITHOUT" => "development:test"),
  sandbox + example + [File.join(world, "first-store")], unpacked, pattern: /"status": "pass"/)

# Remove each implementation/schema in its own copy. All consumers are real;
# the manifest schema is an explicit example preflight, the SQL is read by EV.
{"code" => ["lib/af_evidence/evidence_store.rb", /cannot load such file.*evidence_store/],
 "manifest-schema" => ["schemas/af-evidence-manifest-v0.1.schema.json", /No such file.*manifest/],
 "index-schema" => ["schemas/af-evidence-index-v0.1.sql", /No such file.*index/]
}.each do |label, (relative, pattern)|
  copy = File.join(world, "removed-#{label}")
  FileUtils.cp_r(unpacked, copy)
  File.unlink(File.join(copy, relative))
  checked_command(environment.merge("BUNDLE_GEMFILE" => File.join(copy, "Gemfile"), "BUNDLE_WITHOUT" => "development:test"),
    sandbox + example + [File.join(world, "store-#{label}")], copy, expected: 1, pattern: pattern)
  FileUtils.copy_file(File.join(unpacked, relative), File.join(copy, relative), true)
  raise "Restored package differs" unless SourcePackage.inputs(copy) == SourcePackage.inputs(unpacked)
  checked_command(environment.merge("BUNDLE_GEMFILE" => File.join(copy, "Gemfile"), "BUNDLE_WITHOUT" => "development:test"),
    sandbox + example + [File.join(world, "restored-#{label}")], copy, pattern: /"status": "pass"/)
end

# Reuse the five existing real-zstd mechanical tests for compressor, changed
# evidence and unsafe/existing output refusals; do not duplicate owner tests.
checked_command(environment, sandbox + [RbConfig.ruby, "-rbundler/setup", "-Ilib",
  "test/mechanical_proof_test.rb", "--no-plugins", "--seed=1402"], unpacked,
  pattern: /5 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/)
# The untouched unpacked package is the exact restoration control.
checked_command(environment.merge("BUNDLE_WITHOUT" => "development:test"),
  sandbox + example + [File.join(world, "restored-store")], unpacked, pattern: /"status": "pass"/)
raise "Package inputs changed" unless SourcePackage.inputs(unpacked).map { |record|
  {"path" => record.fetch("path"), "mode" => record.fetch("mode"), "size" => record.fetch("bytes").bytesize,
   "sha256" => Digest::SHA256.hexdigest(record.fetch("bytes"))}
} == records
puts JSON.generate("package_smoke" => "pass", "scratch" => world)
