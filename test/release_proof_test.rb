# frozen_string_literal: true

require "af_evidence"
gem "minitest", "~> 5.0"
require "minitest/autorun"

# Real owner negatives before Git, using generated binary/empty evidence only.
# No Git fixture mutation, fake verifier, or successful release claim.
class ReleaseProofTest < Minitest::Test
  BATCH = "mechanical-release"

  # Supplies a real store/check/report and bound release owner; cleans generated IO.
  def with_proof
    Dir.mktmpdir("ev-release-controls-") do |world|
      source = File.join(world, "source")
      archive = File.join(world, "archive")
      evidence = File.join(archive, "evidence")
      index = File.join(archive, "index.sqlite")
      FileUtils.mkdir_p([source, archive])
      metadata = File.join(source, "mechanical", "runs", "job", "metadata.json")
      FileUtils.mkdir_p(File.dirname(metadata))
      File.write(metadata, JSON.generate("job_id" => "job", "adventure" => "ADV-TEST",
        "dimension" => "mechanical", "status" => "complete"))
      File.binwrite(File.join(source, "binary.bin"), "\0\xff\x80".b)
      File.binwrite(File.join(source, "empty.bin"), "".b)
      store = AfEvidence::EvidenceStore.new(batch_id: BATCH, source_root: source,
        evidence_root: evidence, index_path: index)
      pair = store.ensure_pair!
      store.rebuild_index!
      result = AfEvidence::EvidenceEquivalenceChecker.new(batch_id: BATCH, source_root: source,
        evidence_root: evidence, index_path: index).verify!
      report_path = File.join(evidence, BATCH, "equivalence-report.json")
      report = {"schema_version" => "mechanical-equivalence/v1", "batch_id" => BATCH,
                "valid" => true, "status" => "valid",
                "checks" => result.checks, "inputs" => {
                  "manifest_sha256" => pair.dig("manifest", "sha256"),
                  "bundle_sha256" => pair.dig("bundle", "sha256")}}
      File.write(report_path, JSON.generate(report))
      arguments = {batch_id: BATCH, source_root: source,
                   source_sha256: AfEvidence::EvidenceReleaseProof.source_digest(source),
                   archive_root: archive, evidence_root: evidence, index_path: index,
                   manifest_state: pair.fetch("manifest"), bundle_state: pair.fetch("bundle"),
                   report_state: file_state(report_path), report_schema: "mechanical-equivalence/v1"}
      yield arguments, report_path, report
    end
  end

  # Returns exact bytes/size/path for the generated retained report; IO errors propagate.
  def file_state(path)
    {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
  end

  # Runs real validation and requires the intended invariant before any Git lookup.
  # Every negative retains source and report bytes as observed immediately before.
  def assert_refusal(arguments, pattern)
    source = arguments.fetch(:source_root)
    before = AfEvidence::EvidenceReleaseProof.source_digest(source)
    error = assert_raises(AfEvidence::ValidationError) do
      AfEvidence::EvidenceReleaseProof.new(**arguments).verify!
    end
    assert_match pattern, error.message
    assert File.directory?(source)
    assert_equal before, AfEvidence::EvidenceReleaseProof.source_digest(source)
  end

  # Valid real storage/checks reach Git refusal; ordinary non-Git roots never authorize.
  def test_actual_owners_reach_git_and_refuse_without_retention
    with_proof do |arguments, _path, _report|
      assert_refusal(arguments, /git rev-parse.*failed/)
      error = assert_raises(AfEvidence::ValidationError) do
        AfEvidence::EvidenceReleaseProof.new(**arguments).release!
      end
      assert_match(/durable release authorization validator is required/, error.message)
    end
  end

  # A self-rehashed invalid report still fails its mechanical results and pair binding.
  def test_missing_invalid_and_changed_equivalence_refuse
    with_proof do |arguments, path, report|
      original = File.binread(path)
      File.unlink(path)
      assert_refusal(arguments, /compact artifact is missing/)
      File.binwrite(path, original + "\n")
      assert_refusal(arguments, /equivalence_report changed after finalization/)
      report["checks"]["bundle_expanded_source"]["status"] = "fail"
      File.write(path, JSON.generate(report))
      assert_refusal(arguments.merge(report_state: file_state(path)), /equivalence report is not valid/)
      report["checks"]["bundle_expanded_source"]["status"] = "pass"
      report["inputs"]["manifest_sha256"] = "0" * 64
      File.write(path, JSON.generate(report))
      assert_refusal(arguments.merge(report_state: file_state(path)), /no longer matches the canonical/)
    end
  end

  # Caller-rehashed bundle claims cannot replace actual decompression/member checks.
  def test_rehashed_invalid_bundle_refuses
    with_proof do |arguments, path, report|
      bundle = arguments.fetch(:bundle_state).fetch("path")
      File.binwrite(bundle, "not a bundle")
      manifest_path = arguments.fetch(:manifest_state).fetch("path")
      manifest = JSON.parse(File.binread(manifest_path))
      manifest["bundle"]["sha256"] = Digest::SHA256.file(bundle).hexdigest
      manifest["bundle"]["byte_size"] = File.size(bundle)
      File.write(manifest_path, JSON.generate(manifest))
      report["inputs"]["manifest_sha256"] = Digest::SHA256.file(manifest_path).hexdigest
      report["inputs"]["bundle_sha256"] = Digest::SHA256.file(bundle).hexdigest
      File.write(path, JSON.generate(report))
      assert_refusal(arguments.merge(manifest_state: file_state(manifest_path),
        bundle_state: file_state(bundle), report_state: file_state(path)), /zstd decompression failed/)
    end
  end

  # Detects stale indexes with real rebuild/manifest comparisons and source changes.
  def test_stale_index_and_source_change_refuse
    with_proof do |arguments, _path, _report|
      File.binwrite(File.join(arguments.fetch(:source_root), "binary.bin"), "changed")
      assert_refusal(arguments, /expanded evidence archive changed/)
    end
    with_proof do |arguments, _path, _report|
      database = SQLite3::Database.new(arguments.fetch(:index_path))
      database.execute("UPDATE members SET sha256 = ?", ["0" * 64])
      database.close
      assert_refusal(arguments, /evidence index member inventory differs/)
    end
  end

  # Explicit unrelated receipt paths, overlap and symlink ancestors cannot bind release.
  def test_mismatched_receipt_and_unsafe_root_refuse
    with_proof do |arguments, _path, _report|
      mismatch = arguments.fetch(:manifest_state).merge("path" => "/unrelated/manifest.json")
      assert_refusal(arguments.merge(manifest_state: mismatch), /mismatched path/)
      assert_refusal(arguments.merge(archive_root: File.dirname(arguments.fetch(:source_root))), /roots overlap/)
      link = File.join(File.dirname(arguments.fetch(:source_root)), "source-link")
      File.symlink(arguments.fetch(:source_root), link)
      assert_refusal(arguments.merge(source_root: link), /contains a symlink/)
    end
  end
end
