# frozen_string_literal: true

require "af_evidence"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "stringio"

# Fresh real-zstd proof; generated mechanical bytes only. The preserved baseline
# proof used these same five behaviors before the implementation moved.
class MechanicalProofTest < Minitest::Test
  OWNER = AfEvidence
  BATCH = "prod-batch-mechanical"
  RAW = "mechanical/runs/job/native/raw/ADV-TEST/run-one"
  BINARY = (0..255).to_a.pack("C*") + "\x00\xff".b

  # Creates a disposable recognizable AFIO/native-run corpus; no external calls.
  def with_corpus
    Dir.mktmpdir("ev-real-zstd-") do |world|
      source = File.join(world, "source")
      canonical = File.join(world, "evidence", BATCH)
      FileUtils.mkdir_p([source, canonical])
      write_member(source, "mechanical/runs/job/metadata.json", JSON.generate(
        "job_id" => "job", "adventure" => "ADV-TEST", "dimension" => "mechanical", "status" => "complete"))
      write_member(source, "#{RAW}/run_metadata.json", JSON.generate(
        "run_id" => "run-one", "adventure_id" => "ADV-TEST", "selected_dimension" => "mechanical"))
      write_member(source, "#{RAW}/binary.bin", BINARY)
      write_member(source, "#{RAW}/empty.bin", "")
      manifest_builder = OWNER::EvidenceManifestBuilder.new(batch_root: source, batch_id: BATCH)
      bundle = OWNER::EvidenceBundleBuilder.new(batch_root: source, batch_id: BATCH)
        .build!(output_path: File.join(canonical, "bundle.tar.zst"))
      manifest = File.join(canonical, "manifest.json")
      manifest_builder.write!(output_path: manifest, bundle: bundle.bundle, members: bundle.members)
      yield world, source, File.dirname(canonical), bundle.path, manifest
    end
  end

  # Writes exact fixture bytes under a generated root; filesystem errors propagate.
  def write_member(root, relative, bytes)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
  end

  # Returns stable regular-file byte/mode identities for preservation assertions.
  def inventory(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      .select { |path| File.file?(path) }.map do |path|
        [path.delete_prefix(root + "/"), File.stat(path).mode & 0o777,
         File.size(path), Digest::SHA256.file(path).hexdigest]
      end
  end

  # Builds a real derived index outside the canonical root; validation propagates.
  def build_index(world, evidence)
    path = File.join(world, "index.sqlite")
    OWNER::EvidenceIndexBuilder.new.build!(evidence_root: evidence, output_path: path)
    path
  end

  # Reads all logical records read-only for deletion/rebuild comparison.
  def logical_rows(index)
    database = SQLite3::Database.new(index, readonly: true)
    OWNER::EvidenceIndexVerifier::TABLE_QUERIES.transform_values { |sql| database.execute(sql) }
  ensure
    database&.close
  end

  # Proves deterministic compressed bytes, exact binary/empty retrieval, immutable
  # pair/source, explicit replay refusal and identical logical index rebuild.
  def test_roundtrip_rebuild_and_repeat
    with_corpus do |world, source, evidence, bundle, manifest|
      before = [inventory(source), inventory(evidence)]
      verified = OWNER::EvidenceBundleVerifier.new.verify!(manifest_path: manifest, bundle_path: bundle, source_root: source)
      assert verified.source_verified
      assert_equal 4, verified.member_count
      duplicate = File.join(world, "duplicate", "bundle.tar.zst")
      OWNER::EvidenceBundleBuilder.new(batch_root: source, batch_id: BATCH).build!(output_path: duplicate)
      assert_equal File.binread(bundle), File.binread(duplicate)
      second_manifest = File.join(world, "duplicate", "manifest.json")
      OWNER::EvidenceManifestBuilder.new(batch_root: source, batch_id: BATCH).write!(
        output_path: second_manifest, bundle: JSON.parse(File.read(manifest)).fetch("bundle"))
      assert_equal File.binread(manifest), File.binread(second_manifest)
      index = build_index(world, evidence)
      rows = OWNER::EvidenceIndexLookup.new(index_path: index).lookup(run_id: "run-one")
      retriever = OWNER::EvidenceRetriever.new(evidence_root: evidence)
      {"binary.bin" => BINARY, "empty.bin" => "".b}.each do |name, bytes|
        locator = rows.find { |row| row.fetch("member_path") == "#{RAW}/#{name}" }
        output = File.join(world, name)
        result = retriever.extract_member!(locator: locator, output_path: output)
        assert_equal bytes, File.binread(output)
        assert_equal Digest::SHA256.hexdigest(bytes), result.sha256
      end
      before_rows = logical_rows(index)
      File.unlink(index)
      build_index(world, evidence)
      assert_equal before_rows, logical_rows(index)
      assert_equal 1, OWNER::EvidenceIndexVerifier.new.verify!(evidence_root: evidence, index_path: index).batch_count
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceBundleBuilder.new(batch_root: source, batch_id: BATCH).build!(output_path: bundle)
      end
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceManifestBuilder.new(batch_root: source, batch_id: BATCH).write!(
          output_path: manifest, bundle: JSON.parse(File.read(manifest)).fetch("bundle"))
      end
      assert_equal before, [inventory(source), inventory(evidence)]
    end
  end

  # Corrupts disposable copies, proving real bundle and member validators refuse.
  def test_changed_hashes_refuse
    with_corpus do |world, source, evidence, bundle, manifest|
      before = [inventory(source), inventory(evidence)]
      copy = File.join(world, "corrupt")
      FileUtils.mkdir_p(copy)
      copy_bundle = File.join(copy, "bundle.tar.zst")
      copy_manifest = File.join(copy, "manifest.json")
      FileUtils.cp(bundle, copy_bundle)
      FileUtils.cp(manifest, copy_manifest)
      bytes = File.binread(copy_bundle)
      bytes.setbyte(0, bytes.getbyte(0) ^ 1)
      File.binwrite(copy_bundle, bytes)
      error = assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceBundleVerifier.new.verify!(manifest_path: copy_manifest, bundle_path: copy_bundle)
      end
      assert_match(/bundle sha256 mismatch/, error.message)
      FileUtils.cp(bundle, copy_bundle)
      data = JSON.parse(File.read(copy_manifest))
      data.fetch("members").first["sha256"] = "0" * 64
      File.write(copy_manifest, JSON.generate(data))
      error = assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceBundleVerifier.new.verify!(manifest_path: copy_manifest, bundle_path: copy_bundle)
      end
      assert_match(/member hash mismatch/, error.message)
      assert_equal before, [inventory(source), inventory(evidence)]
    end
  end

  # Recompresses malformed real tar streams with matching bundle hashes so only
  # actual member validation can reject missing/duplicate/extra/escape/link cases.
  def test_malformed_members_refuse
    with_corpus do |world, source, evidence, bundle, manifest|
      before = [inventory(source), inventory(evidence)]
      data = JSON.parse(File.read(manifest))
      members = data.fetch("members").map { |member| [member.fetch("path"), File.binread(File.join(source, member.fetch("path"))), "0"] }
      variants = [
        members.drop(1), members + [members.first], members + [["undeclared.bin", "extra", "0"]],
        [["../escape", "escape", "0"]] + members.drop(1),
        [[members.first[0], members.first[1], "2"]] + members.drop(1)
      ]
      variants.each_with_index do |entries, index|
        directory = File.join(world, "malformed-#{index}")
        FileUtils.mkdir_p(directory)
        tar = File.join(directory, "source.tar")
        File.open(tar, "wb") do |stream|
          entries.each do |path, bytes, type|
            stream.write(Gem::Package::TarHeader.new(name: path, prefix: "", mode: 0o644,
              uid: 0, gid: 0, size: bytes.bytesize, mtime: 0, typeflag: type, uname: "", gname: "").to_s)
            stream.write(bytes)
            stream.write("\0" * ((512 - bytes.bytesize % 512) % 512))
          end
          stream.write("\0" * 1024)
        end
        compressed = File.join(directory, "bundle.tar.zst")
        OWNER::EvidenceBundleBuilder::ZstdCompressor.new.compress!(source_path: tar, output_path: compressed)
        changed = Marshal.load(Marshal.dump(data))
        changed["bundle"]["byte_size"] = File.size(compressed)
        changed["bundle"]["sha256"] = Digest::SHA256.file(compressed).hexdigest
        changed_manifest = File.join(directory, "manifest.json")
        File.write(changed_manifest, JSON.generate(changed))
        assert_raises(OWNER::ValidationError) do
          OWNER::EvidenceBundleVerifier.new.verify!(manifest_path: changed_manifest, bundle_path: compressed)
        end
      end
      assert_equal before, [inventory(source), inventory(evidence)]
    end
  end

  # Rejects a stale derived index, a conflicting source identity and empty input.
  def test_stale_index_conflicting_identity_and_empty_input
    with_corpus do |world, source, evidence, bundle, manifest|
      index = build_index(world, evidence)
      canonical = inventory(evidence)
      database = SQLite3::Database.new(index)
      database.execute("UPDATE members SET sha256 = ?", ["0" * 64])
      database.close
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceIndexVerifier.new.verify!(evidence_root: evidence, index_path: index)
      end
      File.binwrite(File.join(source, "#{RAW}/binary.bin"), "conflicting source")
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceBundleVerifier.new.verify!(manifest_path: manifest, bundle_path: bundle, source_root: source)
      end
      empty = File.join(world, "empty")
      Dir.mkdir(empty)
      assert_raises(OWNER::ValidationError) { OWNER::EvidenceManifestBuilder.new(batch_root: empty, batch_id: BATCH).member_inventory }
      assert_raises(OWNER::ValidationError) { OWNER::EvidenceIndexBuilder.new.build!(evidence_root: empty, output_path: File.join(world, "empty.sqlite")) }
      refute File.exist?(File.join(world, "empty.sqlite"))
      assert_equal canonical, inventory(evidence)
    end
  end

  # Refuses overlapping/existing output, bad locator hashes and missing zstd
  # without retaining incomplete output or changing protected input bytes.
  def test_retrieval_and_compression_refusals
    with_corpus do |world, source, evidence, _bundle, _manifest|
      index = build_index(world, evidence)
      before = [inventory(source), inventory(evidence), File.binread(index)]
      locator = OWNER::EvidenceIndexLookup.new(index_path: index).lookup(run_id: "run-one").first
      retriever = OWNER::EvidenceRetriever.new(evidence_root: evidence)
      existing = File.join(world, "existing")
      File.binwrite(existing, "keep")
      [existing, File.join(evidence, "overlap")].each do |output|
        assert_raises(OWNER::ValidationError) { retriever.extract_member!(locator: locator, output_path: output) }
      end
      assert_equal "keep", File.binread(existing)
      ["bundle_sha256", "member_sha256"].each do |field|
        output = File.join(world, field)
        assert_raises(OWNER::ValidationError) do
          retriever.extract_member!(locator: locator.merge(field => "0" * 64), output_path: output)
        end
        refute File.exist?(output)
      end
      missing = OWNER::EvidenceBundleBuilder::ZstdCompressor.new(command: "/definitely/missing/zstd")
      output = File.join(world, "missing.tar.zst")
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceBundleBuilder.new(batch_root: source, batch_id: BATCH, compressor: missing).build!(output_path: output)
      end
      refute File.exist?(output)
      missing_decompressor = OWNER::EvidenceBundleVerifier::ZstdDecompressor.new(command: "/definitely/missing/zstd")
      decompression_output = File.join(world, "missing-decompression")
      assert_raises(OWNER::ValidationError) do
        OWNER::EvidenceRetriever.new(evidence_root: evidence, decompressor: missing_decompressor)
          .extract_member!(locator: locator, output_path: decompression_output)
      end
      refute File.exist?(decompression_output)
      run_output = File.join(world, "incomplete-run")
      assert_raises(OWNER::ValidationError) do
        retriever.extract_run!(locators: [locator.merge("member_sha256" => "0" * 64)], output_dir: run_output)
      end
      refute File.exist?(run_output)
      assert_equal before, [inventory(source), inventory(evidence), File.binread(index)]
    end
  end
end
