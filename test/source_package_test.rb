# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../script/package"
gem "minitest", "~> 5.0"
ENV["MT_NO_PLUGINS"] = "1"
require "minitest/autorun"

# Tests packaging safety without loading EV, native gems, Git or private data.
class SourcePackageTest < Minitest::Test
  # Copies only reviewed source files into a generated physical root. Yields
  # source/output paths; cleans only its own fixture. Filesystem errors propagate.
  def with_source
    Dir.mktmpdir("ev-package-test-", File.realpath(Dir.tmpdir)) do |world|
      source = File.join(world, "source")
      Dir.mkdir(source)
      original = File.expand_path("..", __dir__)
      SourcePackage.names(original).each do |name|
        target = File.join(source, name)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.copy_file(File.join(original, name), target, true)
      end
      yield source, File.join(world, "source.tar")
    end
  end

  # Reproduces every reviewed byte/mode and excludes unselected local content.
  def test_archive_inventory_and_modes
    with_source do |source, output|
      File.binwrite(File.join(source, "private.data"), "excluded")
      File.chmod(0o755, File.join(source, "script/package.rb"))
      inventory = SourcePackage.build(source, output)
      assert_equal Digest::SHA256.file(output).hexdigest, inventory.fetch("sha256")
      actual = []
      File.open(output, "rb") do |stream|
        Gem::Package::TarReader.new(stream) do |tar|
          tar.each do |entry|
            assert entry.file?
            assert_equal File.binread(File.join(source, entry.full_name)), entry.read
            actual << {"path" => entry.full_name, "mode" => entry.header.mode, "size" => entry.header.size,
                       "sha256" => Digest::SHA256.file(File.join(source, entry.full_name)).hexdigest}
          end
        end
      end
      assert_equal inventory.fetch("files"), actual
      assert_equal SourcePackage.names(source), actual.map { |record| record.fetch("path") }
      refute_includes actual.map { |record| record.fetch("path") }, "private.data"
    end
  end

  # Missing selected implementation cannot produce a partial distribution.
  def test_missing_selected_file
    with_source do |source, output|
      File.unlink(File.join(source, "lib/af_evidence/error.rb"))
      assert_raises(Errno::ENOENT) { SourcePackage.build(source, output) }
      refute File.exist?(output)
    end
  end

  # Direct and ancestor symlinks cannot import external bytes into a package.
  def test_symlinks
    with_source do |source, output|
      File.unlink(File.join(source, "LICENSE"))
      File.symlink(File.join(source, "README.md"), File.join(source, "LICENSE"))
      assert_raises(ArgumentError) { SourcePackage.build(source, output) }
      File.unlink(File.join(source, "LICENSE"))
      File.binwrite(File.join(source, "LICENSE"), "generated test notice")
      File.rename(File.join(source, "lib"), File.join(source, "other-lib"))
      File.symlink(File.join(source, "other-lib"), File.join(source, "lib"))
      assert_raises(ArgumentError) { SourcePackage.build(source, output) }
      refute File.exist?(output)
    end
  end

  # Traversal, absolute, Git, generated, duplicate and omitted setup selections
  # refuse construction instead of broadening the archive allowlist.
  def test_unsafe_or_incomplete_manifest
    with_source do |source, output|
      manifest = File.join(source, "Manifest.txt")
      original = File.binread(manifest)
      ["../private", "/absolute", ".git/config", "coverage/report.json", "README.md", "lib/../private.rb"].each do |name|
        File.binwrite(manifest, original + name + "\n")
        assert_raises(ArgumentError) { SourcePackage.build(source, output) }
      end
      File.binwrite(manifest, original.lines.reject { |line| line == "Gemfile\n" }.join)
      assert_raises(ArgumentError) { SourcePackage.build(source, output) }
      %w[lib/af_evidence/error.rb schemas/af-evidence-index-v0.1.sql].each do |name|
        File.binwrite(manifest, original.lines.reject { |line| line == name + "\n" }.join)
        assert_raises(ArgumentError) { SourcePackage.build(source, output) }
      end
      refute File.exist?(output)
    end
  end

  # Existing outputs and aliases preserve protected bytes; outputs in source
  # refuse. No test changes real Git administration or installed configuration.
  def test_protected_output
    with_source do |source, output|
      File.binwrite(output, "protected")
      assert_raises(Errno::EEXIST) { SourcePackage.build(source, output) }
      assert_equal "protected", File.binread(output)
      link = output + ".link"
      File.symlink(output, link)
      assert_raises(ArgumentError) { SourcePackage.build(source, link) }
      assert_equal "protected", File.binread(output)
      assert_raises(ArgumentError) { SourcePackage.build(source, File.join(source, "output.tar")) }
    end
  end
end
