# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "rubygems/package"

# Builds the private source distribution from Manifest.txt, without loading EV.
module SourcePackage
  ROOT_FILES = %w[Manifest.txt LICENSE Gemfile Gemfile.lock .simplecov COVERAGE.md
                  coverage-baseline.json README.md Rakefile script/package.rb
                  script/package_smoke.rb examples/first_store.rb
                  lib/af_evidence.rb schemas/af-evidence-index-v0.1.sql
                  schemas/af-evidence-manifest-v0.1.schema.json
                  test/run_tests.rb test/coverage_setup.rb].freeze

  # Returns reviewed relative names; rejects missing closure, duplicates and unsafe
  # paths with ArgumentError. File errors propagate. No directory glob is archived.
  def self.names(root)
    manifest = File.join(root, "Manifest.txt")
    raise ArgumentError, "unsafe Manifest.txt" if File.symlink?(manifest)

    names = File.readlines(manifest, chomp: true)
    unless names.uniq == names && (ROOT_FILES - names).empty? && names.all? { |name|
      ROOT_FILES.include?(name) || name.match?(%r{\Alib/(?:af_evidence|af_evidence/[a-z_]+)\.rb\z}) ||
        %w[schemas/af-evidence-index-v0.1.sql schemas/af-evidence-manifest-v0.1.schema.json].include?(name) ||
        name.match?(%r{\Atest/[a-z_]+\.rb\z})
    }
      raise ArgumentError, "unsafe, duplicate or incomplete manifest"
    end
    names
  end

  # Snapshots regular selected files with exact modes/bytes, refusing symlink
  # ancestors, missing inputs and special modes. Returns archive input records;
  # ArgumentError and filesystem errors propagate before any output is created.
  def self.inputs(root)
    names(root).map do |name|
      source = File.join(root, name)
      current = source
      until current == root
        raise ArgumentError, "symlink selected: #{name}" if File.symlink?(current)
        current = File.dirname(current)
      end
      stat = File.lstat(source)
      mode = stat.mode & 0o7777
      raise ArgumentError, "unsafe selected file: #{name}" unless stat.file? && [0o644, 0o755].include?(mode)

      {"path" => name, "mode" => mode, "bytes" => File.binread(source)}
    end
  end

  # Writes an absent tar outside the physical source root and returns hashes and
  # modes for every selected file. Unsafe/conflicting output raises ArgumentError
  # or a filesystem error. Only this call's incomplete output is removed on error.
  def self.build(root, output)
    root = File.realpath(root)
    output = File.expand_path(output)
    unless output != root && !output.start_with?(root + "/") &&
           File.realpath(File.dirname(output)) == File.dirname(output) && !File.symlink?(output)
      raise ArgumentError, "output must be outside source with a real parent"
    end
    records = inputs(root)
    entrypoint = records.find { |record| record.fetch("path") == "lib/af_evidence.rb" }.fetch("bytes")
    required = entrypoint.scan(/^require_relative "([a-z_\/]+)"$/).flatten.map { |name| "lib/#{name}.rb" }
    unless (required - records.map { |record| record.fetch("path") }).empty?
      raise ArgumentError, "entry-point implementation omitted from manifest"
    end
    created = false
    begin
      File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |stream|
        created = true
        Gem::Package::TarWriter.new(stream) do |tar|
          records.each do |record|
            tar.add_file_simple(record.fetch("path"), record.fetch("mode"), record.fetch("bytes").bytesize) do |member|
              member.write(record.fetch("bytes"))
            end
          end
        end
      end
      raise ArgumentError, "selected inputs changed during packaging" unless records == inputs(root)
      {"schema" => "af-evidence-source-package/v1", "archive" => output,
       "sha256" => Digest::SHA256.file(output).hexdigest,
       "files" => records.map { |record| {"path" => record.fetch("path"), "mode" => record.fetch("mode"),
         "size" => record.fetch("bytes").bytesize, "sha256" => Digest::SHA256.hexdigest(record.fetch("bytes"))} }}
    rescue Exception
      File.unlink(output) if created && File.file?(output)
      raise
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby script/package.rb NEW_ABSOLUTE_ARCHIVE.tar" unless ARGV.length == 1 && Pathname.new(ARGV.first).absolute?
  puts JSON.pretty_generate(SourcePackage.build(File.expand_path("..", __dir__), ARGV.fetch(0)))
end
