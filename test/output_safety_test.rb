# frozen_string_literal: true

require "af_evidence"
gem "minitest", "~> 5.0"
require "minitest/autorun"

# Local EV safety does not depend on pipeline authorization or environment.
class OutputSafetyTest < Minitest::Test
  # Provides disposable real directories and removes only the generated world.
  def with_paths
    Dir.mktmpdir("ev-output-safety-") do |world|
      evidence = File.join(world, "evidence")
      parent = File.join(world, "output")
      FileUtils.mkdir_p([evidence, parent])
      yield world, evidence, parent, AfEvidence::OutputSafety.new(evidence_root: evidence)
    end
  end

  # Refuses direct, dangling and ancestor links without touching their targets.
  def test_symlinks_and_traversal_refuse
    with_paths do |world, evidence, parent, safety|
      File.symlink(parent, File.join(world, "alias"))
      File.symlink(File.join(world, "missing"), File.join(parent, "dangling"))
      File.symlink(evidence, File.join(parent, "canonical-link"))
      ["", " ", "bad\0path", File.join(parent, "..", "escape"), File.join(parent, ".", "hidden"),
       File.join(world, "alias", "new"), File.join(parent, "dangling"),
       File.join(parent, "canonical-link", "new")].each do |path|
        assert_raises(AfEvidence::ValidationError) { safety.destination!(path) }
      end
      assert_empty Dir.children(evidence)
      assert_equal %w[canonical-link dangling], Dir.children(parent).sort
    end
  end

  # Refuses overlap, existing files/directories, absent parents and unwritable
  # destinations; a successful check returns a path without publishing anything.
  def test_conflicts_and_safe_destination
    with_paths do |world, evidence, parent, safety|
      existing = File.join(parent, "existing")
      File.binwrite(existing, "protected")
      [existing, parent, File.join(evidence, "new"), File.join(world, "absent", "new")].each do |path|
        assert_raises(AfEvidence::ValidationError) { safety.destination!(path) }
      end
      output = File.join(parent, "new")
      assert_equal output, safety.destination!(output)
      refute File.exist?(output)
      File.chmod(0o500, parent)
      assert_raises(AfEvidence::ValidationError) { safety.destination!(output) }
      assert_equal "protected", File.binread(existing)
    ensure
      File.chmod(0o700, parent)
    end
  end
end
