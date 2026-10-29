# frozen_string_literal: true

module AfEvidence
  # Four mechanical equivalence checks, without production labels or completion policy.
  # Optional verified states are trusted in-process reuse only, never release authority.
  class EvidenceEquivalenceChecker
    CHECK_NAMES = %w[
      expanded_manifest_inventory
      bundle_expanded_source
      index_batch_manifest
      whole_index_rebuild
    ].freeze

    Result = Data.define(:manifest, :checks)

    # Retains partial mechanical results and the original exception for the caller's report.
    class Failure < ValidationError
      attr_reader :manifest, :checks, :error

      # Binds failed checks/input manifest and cause; returns an exception without IO.
      def initialize(message, manifest:, checks:, error:)
        @manifest = manifest
        @checks = checks
        @error = error
        super(message)
      end
    end

    # Binds explicit batch/source/store/index inputs. Reuse states must originate
    # from this process's real verification; they are not an external proof API.
    def initialize(batch_id:, source_root:, evidence_root:, index_path:,
      progress: nil, verified_bundle: nil, verified_index: nil)
      @batch_id = batch_id.to_s
      @source_root = File.expand_path(source_root)
      @evidence_root = File.expand_path(evidence_root)
      @index_path = File.expand_path(index_path)
      @batch_dir = File.join(@evidence_root, @batch_id)
      @manifest_path = File.join(@batch_dir, "manifest.json")
      @progress = progress
      @verified_bundle = verified_bundle
      @verified_index = verified_index
    end

    # Runs four checks and returns manifest/check results; Failure retains partial checks and the cause.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verify!
      checks = CHECK_NAMES.to_h { |name| [name, { "status" => "not_run" }] }
      manifest = nil

      begin
        run_check!(checks, "expanded_manifest_inventory") do
          manifest = load_manifest!
          observed = EvidenceManifestBuilder.new(
            batch_root: @source_root,
            batch_id: @batch_id
          ).member_inventory
          declared = manifest.fetch("members")
          unless observed == declared
            raise ValidationError, inventory_mismatch_message(declared, observed)
          end

          {
            "member_count" => observed.length,
            "byte_size" => observed.sum { |member| member.fetch("byte_size") },
            "inventory_sha256" => inventory_sha256(observed)
          }
        end

        run_check!(checks, "bundle_expanded_source") do
          if @verified_bundle
            verify_preverified_bundle!(manifest)
          else
            bundle_path = bundle_path_for(manifest)
            verified = EvidenceBundleVerifier.new.verify!(
              manifest_path: @manifest_path,
              bundle_path:,
              source_root: @source_root
            )
            unless verified.batch_id == @batch_id && verified.source_verified
              raise ValidationError, "bundle/source verification did not bind #{@batch_id} to the expanded archive"
            end

            {
              "member_count" => verified.member_count,
              "bundle_sha256" => verified.bundle_sha256
            }
          end
        end

        run_check!(checks, "index_batch_manifest") do
          verify_index_batch!(manifest)
        end

        run_check!(checks, "whole_index_rebuild") do
          if @verified_index
            verify_preverified_index!
          else
            verified = EvidenceIndexVerifier.new.verify!(
              evidence_root: @evidence_root,
              index_path: @index_path
            )
            {
              "index_sha256" => verified.index_sha256,
              "batch_count" => verified.batch_count,
              "member_count" => verified.member_count,
              "job_count" => verified.job_count,
              "run_count" => verified.run_count
            }
          end
        end

        Result.new(manifest:, checks:)
      rescue StandardError => error
        raise if error.is_a?(Failure)

        raise Failure.new(error.message, manifest:, checks:, error:)
      end
    end

    private

    # Records the named check result or failure in the supplied mapping, then returns or reraises.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def run_check!(checks, name)
      progress("[evidence-equivalence] checking #{name}")
      value = yield
      details = value.is_a?(Hash) ? value : {}
      checks[name] = { "status" => "pass" }.merge(details)
      { value: }
    rescue StandardError => e
      checks[name] = {
        "status" => "fail",
        "error_class" => e.class.name,
        "error" => e.message
      }
      raise
    end

    # Loads the bound manifest and validates batch/source/index prerequisites; returns the manifest.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def load_manifest!
      unless EvidenceManifestBuilder::BATCH_ID_RE.match?(@batch_id)
        raise ValidationError, "equivalence batch_id is invalid: #{@batch_id.inspect}"
      end
      raise ValidationError, "expanded evidence source does not exist: #{@source_root}" unless File.directory?(@source_root)
      raise ValidationError, "expanded evidence source may not be a symlink: #{@source_root}" if File.symlink?(@source_root)
      raise ValidationError, "canonical evidence root does not exist: #{@evidence_root}" unless File.directory?(@evidence_root)
      raise ValidationError, "canonical evidence root may not be a symlink: #{@evidence_root}" if File.symlink?(@evidence_root)
      raise ValidationError, "evidence manifest is missing: #{@manifest_path}" unless File.file?(@manifest_path)
      raise ValidationError, "evidence manifest may not be a symlink: #{@manifest_path}" if File.symlink?(@manifest_path)
      raise ValidationError, "evidence index is missing: #{@index_path}" unless File.file?(@index_path)
      raise ValidationError, "evidence index may not be a symlink: #{@index_path}" if File.symlink?(@index_path)

      manifest = JSON.parse(File.binread(@manifest_path))
      raise ValidationError, "evidence manifest must be a mapping" unless manifest.is_a?(Hash)
      unless manifest["batch_id"] == @batch_id
        raise ValidationError,
              "evidence manifest batch_id mismatch: expected=#{@batch_id.inspect} actual=#{manifest['batch_id'].inspect}"
      end
      unless manifest["members"].is_a?(Array) && !manifest["members"].empty?
        raise ValidationError, "evidence manifest members must be a non-empty list"
      end
      manifest
    rescue JSON::ParserError => e
      raise ValidationError, "invalid evidence manifest JSON: #{e.message}"
    end

    # Returns a path-level mismatch diagnostic for the supplied declared and observed inventories.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def inventory_mismatch_message(declared, observed)
      declared_by_path = declared.to_h { |member| [member.fetch("path"), member] }
      observed_by_path = observed.to_h { |member| [member.fetch("path"), member] }
      missing = declared_by_path.keys - observed_by_path.keys
      extra = observed_by_path.keys - declared_by_path.keys
      changed = (declared_by_path.keys & observed_by_path.keys).select do |path|
        declared_by_path.fetch(path) != observed_by_path.fetch(path)
      end
      "expanded evidence differs from manifest: " \
        "missing=#{missing.sort.inspect} extra=#{extra.sort.inspect} changed=#{changed.sort.inspect}"
    end

    # Returns the ordered path/size/hash inventory digest; incomplete member mappings raise KeyError.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def inventory_sha256(members)
      digest = Digest::SHA256.new
      members.each do |member|
        digest << member.fetch("path") << "\0"
        digest << member.fetch("byte_size").to_s << "\0"
        digest << member.fetch("sha256") << "\n"
      end
      digest.hexdigest
    end

    # Checks trusted in-process pair reuse against actual installed bytes and returns bundle check details.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verify_preverified_bundle!(manifest)
      state = @verified_bundle
      bundle_path = bundle_path_for(manifest)
      valid = state.is_a?(Hash) &&
        state["source_verified"] == true &&
        state["member_count"] == manifest.fetch("member_count") &&
        verified_file_state?(state["manifest"], @manifest_path) &&
        verified_file_state?(state["bundle"], bundle_path) &&
        state.dig("bundle", "sha256") == manifest.dig("bundle", "sha256")
      raise ValidationError, "preverified evidence bundle no longer matches installed artifacts" unless valid

      {
        "member_count" => state.fetch("member_count"),
        "bundle_sha256" => state.fetch("bundle").fetch("sha256")
      }
    end

    # Checks trusted in-process index reuse, current bytes and counts; returns index check details.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verify_preverified_index!
      state = @verified_index
      counts = %w[batch_count member_count job_count run_count].to_h do |key|
        [key, state.is_a?(Hash) ? state[key] : nil]
      end
      valid = state.is_a?(Hash) &&
        state["verified"] == true &&
        verified_file_state?(state, @index_path) &&
        counts.values.all? { |value| value.is_a?(Integer) && value >= 0 }
      raise ValidationError, "preverified evidence index no longer matches installed artifacts" unless valid

      {
        "index_sha256" => state.fetch("sha256")
      }.merge(counts)
    end

    # Returns whether the supplied file receipt exactly matches the expected path and current bytes.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verified_file_state?(state, expected_path)
      state.is_a?(Hash) &&
        File.expand_path(state["path"].to_s) == expected_path &&
        File.file?(expected_path) &&
        !File.symlink?(expected_path) &&
        state["bytes"] == File.size(expected_path) &&
        state["sha256"] == Digest::SHA256.file(expected_path).hexdigest
    end

    # Returns the manifest-named regular bundle within this batch; unsafe/missing paths refuse.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def bundle_path_for(manifest)
      bundle = manifest["bundle"]
      raise ValidationError, "evidence manifest bundle must be a mapping" unless bundle.is_a?(Hash)
      filename = bundle["filename"].to_s
      unless !filename.empty? && filename == File.basename(filename) && !filename.include?("\\")
        raise ValidationError, "evidence manifest bundle.filename must be a basename"
      end

      path = File.join(@batch_dir, filename)
      raise ValidationError, "evidence bundle is missing: #{path}" unless File.file?(path)
      raise ValidationError, "evidence bundle may not be a symlink: #{path}" if File.symlink?(path)
      path
    end

    # Compares real read-only indexed batch/member rows to the manifest and returns their identities.
    # Invalid inputs raise ValidationError; IO/dependency/callback errors propagate.
    def verify_index_batch!(manifest)
      database = SQLite3::Database.new(@index_path, readonly: true)
      database.execute("PRAGMA query_only = ON")
      bundle = manifest.fetch("bundle")
      manifest_sha256 = Digest::SHA256.file(@manifest_path).hexdigest
      expected_batch = [
        manifest.fetch("schema_version"),
        manifest_sha256,
        bundle.fetch("filename"),
        bundle.fetch("format"),
        bundle.fetch("profile_version"),
        bundle.fetch("byte_size"),
        bundle.fetch("sha256"),
        manifest.fetch("member_count")
      ]
      actual_batch = database.get_first_row(
        <<~SQL,
          SELECT manifest_schema_version, manifest_sha256, bundle_filename,
                 bundle_format, bundle_profile_version, bundle_byte_size,
                 bundle_sha256, member_count
          FROM batches
          WHERE batch_id = ?
        SQL
        [@batch_id]
      )
      raise ValidationError, "evidence index is missing batch #{@batch_id}" unless actual_batch
      unless actual_batch == expected_batch
        raise ValidationError, "evidence index batch metadata differs from manifest for #{@batch_id}"
      end

      expected_members = manifest.fetch("members").map do |member|
        [member.fetch("path"), member.fetch("byte_size"), member.fetch("sha256")]
      end
      actual_members = database.execute(
        <<~SQL,
          SELECT member_path, byte_size, sha256
          FROM members
          WHERE batch_id = ?
          ORDER BY member_path
        SQL
        [@batch_id]
      )
      unless actual_members == expected_members
        raise ValidationError, "evidence index member inventory differs from manifest for #{@batch_id}"
      end

      {
        "manifest_sha256" => manifest_sha256,
        "member_count" => actual_members.length,
        "inventory_sha256" => inventory_sha256(manifest.fetch("members"))
      }
    rescue SQLite3::Exception => e
      raise ValidationError, "evidence index batch comparison failed: #{e.message}"
    ensure
      database&.close rescue nil
    end

    # Delivers mechanical check progress; observer exceptions propagate.
    def progress(message)
      @progress&.call(message)
    end
  end
end
