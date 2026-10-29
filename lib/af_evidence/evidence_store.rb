# frozen_string_literal: true

module AfEvidence
  # Pair reuse and atomic publication of the independently verified derived index.
  # Roots are selected by the caller; this owner never decides operation completion.
  class EvidenceStore
    MANIFEST_FILENAME = "manifest.json"

    # Binds an explicit batch/source/canonical root/index and optional progress observer.
    # Invalid identifiers/paths raise ValidationError; IO errors propagate.
    def initialize(batch_id:, source_root:, evidence_root:, index_path:, progress: nil)
      [source_root, evidence_root, index_path].each do |path|
        unless path.is_a?(String) && Pathname.new(path).absolute? && !path.include?("\0") &&
               path.split(File::SEPARATOR).none? { |part| %w[. ..].include?(part) }
          raise ValidationError, "Evidence paths must be explicit absolute paths without traversal"
        end
      end
      @batch_id = batch_id.to_s
      @source_root = File.expand_path(source_root)
      @evidence_root = File.expand_path(evidence_root)
      @index_path = File.expand_path(index_path)
      @index_dir = File.dirname(@index_path)
      @batch_dir = File.join(@evidence_root, @batch_id)
      @manifest_path = File.join(@batch_dir, MANIFEST_FILENAME)
      @bundle_path = File.join(@batch_dir, "#{@batch_id}.tar.zst")
      @progress = progress
      unless EvidenceManifestBuilder::BATCH_ID_RE.match?(@batch_id)
        raise ValidationError, "Evidence batch_id is invalid: #{@batch_id.inspect}"
      end
      unless File.directory?(@source_root) && !File.symlink?(@source_root)
        raise ValidationError, "Expanded evidence source is not a real directory: #{@source_root}"
      end
      [@source_root, @evidence_root, @index_path].each do |path|
        current = path
        loop do
          raise ValidationError, "Evidence path contains a symlink: #{current}" if File.symlink?(current)
          break if current == File.dirname(current)

          current = File.dirname(current)
        end
      end
      if @evidence_root == @source_root || @evidence_root.start_with?(@source_root + "/") ||
         @source_root.start_with?(@evidence_root + "/") ||
         [@source_root, @evidence_root].include?(@index_path) ||
         @index_path.start_with?(@source_root + "/") || @index_path.start_with?(@evidence_root + "/")
        raise ValidationError, "Evidence source, canonical root and index must not overlap"
      end
    end

    # Reuses an exact verified pair or exclusively installs a newly verified pair; returns its file/count receipt.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def ensure_pair!
      FileUtils.mkdir_p(@evidence_root)
      if File.exist?(@batch_dir) || File.symlink?(@batch_dir)
        unless File.directory?(@batch_dir) && !File.symlink?(@batch_dir)
          raise ValidationError, "Canonical evidence batch path is invalid: #{@batch_dir}"
        end
        progress("existing #{@batch_id} canonical batch found; verifying")
        verification = verify_batch!(@manifest_path, @bundle_path)
        return canonical_batch_state(verification)
      end

      staging = Dir.mktmpdir(".#{@batch_id}-evidence-", File.dirname(@evidence_root))
      begin
        progress("inventorying #{@batch_id} expanded evidence")
        manifest_builder = EvidenceManifestBuilder.new(batch_root: @source_root, batch_id: @batch_id)
        members = manifest_builder.member_inventory(progress: evidence_progress)

        staging_bundle = File.join(staging, "#{@batch_id}.tar.zst")
        staging_manifest = File.join(staging, MANIFEST_FILENAME)
        progress("building deterministic #{@batch_id} evidence bundle")
        bundle = EvidenceBundleBuilder.new(batch_root: @source_root, batch_id: @batch_id).build!(
          output_path: staging_bundle,
          members:,
          progress: evidence_progress
        )
        manifest_builder.write!(
          output_path: staging_manifest,
          bundle: bundle.bundle,
          members: bundle.members
        )

        progress("verifying bundle against expanded source")
        verification = verify_batch!(staging_manifest, staging_bundle)
        File.rename(staging, @batch_dir)
        progress("installed #{@batch_id} canonical bundle + manifest")
        canonical_batch_state(verification)
      ensure
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
      end
    end

    # Verifies the supplied pair against this source/batch and returns the real verifier result.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verify_batch!(manifest_path, bundle_path)
      verification = EvidenceBundleVerifier.new.verify!(
        manifest_path:,
        bundle_path:,
        source_root: @source_root
      )
      unless verification.batch_id == @batch_id && verification.source_verified
        raise ValidationError, "Evidence verification did not bind #{@batch_id} to the expanded source"
      end
      verification
    end

    # Returns installed pair paths, byte identities and counts from the supplied verifier result.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def canonical_batch_state(verification)
      {
        "path" => @batch_dir,
        "manifest" => file_state(@manifest_path),
        "bundle" => file_state(@bundle_path),
        "member_count" => verification.member_count,
        "source_verified" => verification.source_verified
      }
    end

    # Builds and independently verifies a new index, atomically replaces the bound index, and returns its receipt.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def rebuild_index!
      FileUtils.mkdir_p(@index_dir)
      if File.symlink?(@index_path)
        raise ValidationError, "Evidence index may not be a symlink: #{@index_path}"
      end

      candidate = File.join(
        @index_dir,
        ".#{File.basename(@index_path)}.tmp-#{$$}-#{rand(1_000_000)}"
      )
      begin
        progress("rebuilding derived evidence index")
        EvidenceIndexBuilder.new.build!(
          evidence_root: @evidence_root,
          output_path: candidate
        )
        verified = EvidenceIndexVerifier.new.verify!(
          evidence_root: @evidence_root,
          index_path: candidate
        )
        File.rename(candidate, @index_path)
        progress("installed verified derived evidence index")

        file_state(@index_path).merge(
          "verified" => true,
          "batch_count" => verified.batch_count,
          "member_count" => verified.member_count,
          "job_count" => verified.job_count,
          "run_count" => verified.run_count
        )
      ensure
        FileUtils.rm_f(candidate)
      end
    end

    private :verify_batch!, :canonical_batch_state

    private

    # Returns absolute path, SHA-256 and size for the supplied regular artifact.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def file_state(path)
      {
        "path" => File.expand_path(path),
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path)
      }
    end

    # Returns an optional inventory/bundle progress translator without changing evidence.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def evidence_progress
      return nil unless @progress

      lambda do |event|
        phase = event.fetch(:phase)
        current = event.fetch(:current)
        total = event.fetch(:total)
        case phase
        when :manifest_inventory
          progress("inventory #{current}/#{total} files")
        when :bundle_tar
          progress("bundle #{current}/#{total} files")
        end
      end
    end

    # Sends the supplied storage progress message; returns the observer result or nil.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def progress(message)
      @progress&.call(message)
    end
  end
end
