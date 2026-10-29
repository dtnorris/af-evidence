# frozen_string_literal: true

module AfEvidence
  # Fresh source/pair/report/current-index and local-HEAD retention proof.
  # No production completion, private-root selection or state-file interpretation.
  class EvidenceReleaseProof
    Result = Data.define(:git_head, :committed_artifacts)

    # Binds the exact operation/source/archive and finalized pair/report receipts.
    # Paths must be explicit; invalid bindings raise ValidationError on verification.
    def initialize(batch_id:, source_root:, source_sha256:, archive_root:, evidence_root:,
      index_path:, manifest_state:, bundle_state:, report_state:, report_schema:)
      [source_root, archive_root, evidence_root, index_path].each do |path|
        unless path.is_a?(String) && Pathname.new(path).absolute? && !path.include?("\0") &&
               path.split(File::SEPARATOR).none? { |part| %w[. ..].include?(part) }
          raise ValidationError, "release paths must be explicit absolute paths without traversal"
        end
      end
      @batch_id = batch_id.to_s
      @source_root = File.expand_path(source_root)
      @source_sha256 = source_sha256
      @report_schema = report_schema
      @archive_root = File.expand_path(archive_root)
      @evidence_root = File.expand_path(evidence_root)
      @index_path = File.expand_path(index_path)
      @batch_dir = File.join(@evidence_root, @batch_id)
      @manifest_path = File.join(@batch_dir, "manifest.json")
      @bundle_path = File.join(@batch_dir, "#{@batch_id}.tar.zst")
      @report_path = File.join(@batch_dir, "equivalence-report.json")
      @states = {"manifest" => manifest_state, "bundle" => bundle_state,
                 "equivalence_report" => report_state}
    end

    # Independently verifies all bound bytes and current Git retention, returning
    # four artifact records and HEAD. Never trusts reuse receipts or policy flags.
    # Invalid evidence raises ValidationError; IO/dependency errors propagate.
    def verify!
      validate_bindings!
      verify_source!
      before = artifact_states
      @states.each do |kind, state|
        unless state.is_a?(Hash) && state["path"] &&
               File.expand_path(state["path"]) == artifact_paths.fetch(kind) &&
               state["sha256"] == before.fetch(kind).fetch("sha256") &&
               (!state.key?("bytes") || state["bytes"] == before.fetch(kind).fetch("bytes"))
          raise ValidationError, "#{kind} changed after finalization or has a mismatched path"
        end
      end
      verify_report!
      # Always run all real checks; serialized/in-process reuse cannot authorize release.
      EvidenceEquivalenceChecker.new(batch_id: @batch_id, source_root: @source_root,
        evidence_root: @evidence_root, index_path: @index_path).verify!
      head = git_head!
      artifacts = verify_committed_artifacts!
      unless artifact_states == before && git_head! == head
        raise ValidationError, "compact evidence or HEAD changed during release proof"
      end
      verify_source!
      Result.new(git_head: head, committed_artifacts: artifacts)
    end

    # Repeats fresh real proof, then requires the caller's bound durable-state
    # validation block before removing this source only. No serialized proof is
    # accepted. The trusted caller owns authorization and must raise on mismatch.
    # Missing authorization or changed evidence raises ValidationError; callback
    # errors propagate without deletion. This is not a hostile-writer transaction.
    def release!
      raise ValidationError, "durable release authorization validator is required" unless block_given?

      proof = verify!
      yield proof
      verify_source!
      FileUtils.remove_entry(@source_root)
      if File.exist?(@source_root) || File.symlink?(@source_root)
        raise ValidationError, "expanded evidence release did not remove #{@source_root}"
      end
      proof
    end

    # Returns the legacy sorted path/hash digest for an explicit expanded source.
    # This digest alone is not source proof; verify! additionally validates the
    # inventory and canonical pair. IO errors propagate.
    def self.source_digest(path)
      digest = Digest::SHA256.new
      files = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
        .select { |item| File.file?(item) }.sort
      files.each do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(path)).to_s
        digest << relative << "\0" << Digest::SHA256.file(file).hexdigest << "\n"
      end
      digest.hexdigest
    end

    private

    # Checks operation identity and real, disjoint roots, rejecting path/ancestor
    # links and artifacts outside the selected archive. Returns nil or raises.
    def validate_bindings!
      unless EvidenceManifestBuilder::BATCH_ID_RE.match?(@batch_id) &&
             @source_sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(@source_sha256)
        raise ValidationError, "release operation/source binding is invalid"
      end
      [@source_root, @archive_root, @evidence_root, *artifact_paths.values].each do |path|
        current = path
        loop do
          raise ValidationError, "release path contains a symlink: #{current}" if File.symlink?(current)
          break if current == File.dirname(current)

          current = File.dirname(current)
        end
      end
      [@source_root, @archive_root, @evidence_root].each do |root|
        raise ValidationError, "release root is not a directory: #{root}" unless File.directory?(root)
      end
      if within?(@source_root, @archive_root) || within?(@archive_root, @source_root) ||
         !within?(@evidence_root, @archive_root) || within?(@index_path, @evidence_root)
        raise ValidationError, "release source and archive roots overlap or have unsafe bindings"
      end
      artifact_paths.each_value { |path| repo_relative_path(path) }
      nil
    end

    # Returns containment for expanded absolute paths without filesystem mutation.
    def within?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end

    # Re-inventories real source bytes, then compares the finalized legacy digest.
    # Links, missing source and changed bytes raise ValidationError.
    def verify_source!
      EvidenceManifestBuilder.new(batch_root: @source_root, batch_id: @batch_id).member_inventory
      unless self.class.source_digest(@source_root) == @source_sha256
        raise ValidationError, "expanded evidence archive changed after production finalization: #{@source_root}"
      end
    end

    # Returns the four exact artifact paths; no state interpretation or IO.
    def artifact_paths
      {"manifest" => @manifest_path, "bundle" => @bundle_path,
       "equivalence_report" => @report_path, "index" => @index_path}
    end

    # Hashes all four real regular files; missing/linked files raise ValidationError.
    def artifact_states
      artifact_paths.transform_values do |path|
        unless File.file?(path) && !File.symlink?(path)
          raise ValidationError, "compact artifact is missing or unsafe: #{path}"
        end
        {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
      end
    end

    # Validates stored mechanical results and exact pair bindings. The report's
    # historic index hash is not the current index: a later corpus may grow.
    # Fresh whole-index proof above is always required. Policy stays with PL.
    def verify_report!
      report = JSON.parse(File.binread(@report_path))
      unless report.is_a?(Hash) && report["schema_version"] == @report_schema &&
             @report_schema.is_a?(String) && !@report_schema.empty? && report["batch_id"] == @batch_id &&
             report["status"] == "valid" && report["valid"] == true &&
             report["checks"].is_a?(Hash) && report["inputs"].is_a?(Hash) &&
             EvidenceEquivalenceChecker::CHECK_NAMES.all? do |name|
               check = report["checks"][name]
               check.is_a?(Hash) && check["status"] == "pass"
             end
        raise ValidationError, "equivalence report is not valid for #{@batch_id}"
      end
      unless report.dig("inputs", "manifest_sha256") == Digest::SHA256.file(@manifest_path).hexdigest &&
             report.dig("inputs", "bundle_sha256") == Digest::SHA256.file(@bundle_path).hexdigest
        raise ValidationError, "equivalence report no longer matches the canonical manifest/bundle"
      end
    rescue JSON::ParserError => error
      raise ValidationError, "equivalence report parse failure: #{error.message}"
    end

    # Requires the explicitly selected archive to be the actual Git worktree root.
    # Returns local HEAD; invalid roots/Git failures raise ValidationError.
    def git_head!
      top = git_stdout!("rev-parse", "--show-toplevel").strip
      unless File.realpath(top) == @archive_root && File.expand_path(top) == @archive_root
        raise ValidationError, "archive path is not the Git worktree root: #{@archive_root}"
      end
      git_stdout!("rev-parse", "HEAD").strip
    end

    # Compares actual HEAD blobs, stage-zero index entries and working bytes for
    # all four files. Returns legacy kind/path/hash/size records or raises.
    def verify_committed_artifacts!
      artifacts = artifact_paths.map { |kind, path| [kind, path, repo_relative_path(path)] }
      relatives = artifacts.map { |_kind, _path, relative| relative }
      tree = git_stdout!("ls-tree", "-r", "-z", "HEAD", "--", *relatives).split("\0").to_h do |record|
        metadata, relative = record.split("\t", 2)
        [relative, metadata.split(" ")]
      end
      if (missing = artifacts.find { |_kind, _path, relative| !tree.key?(relative) })
        raise ValidationError, "#{missing[0]} is not committed in llm-response-data HEAD: #{missing[2]}"
      end
      staged = git_stdout!("ls-files", "--stage", "-z", "--", *relatives).split("\0").group_by do |record|
        record.split("\t", 2).last
      end
      artifacts.map do |kind, path, relative|
        mode, type, object = tree.fetch(relative)
        expected_stage = "#{mode} #{object} 0\t#{relative}"
        unless %w[100644 100755].include?(mode) && type == "blob" && staged[relative] == [expected_stage] &&
               ((File.stat(path).mode & 0o111).positive? == (mode == "100755")) &&
               File.binread(path) == git_stdout!("cat-file", "blob", object)
          raise ValidationError, "#{kind} differs from committed llm-response-data HEAD: #{relative}"
        end
        {"kind" => kind, "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest,
         "bytes" => File.size(path)}
      end
    end

    # Captures raw Git bytes without shell, external configuration, hooks or locks.
    # Nonzero status/spawn failure raises ValidationError; output stays binary.
    def git_stdout!(*arguments)
      environment = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
                     "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_COUNT" => "0",
                     "GIT_NO_LAZY_FETCH" => "1", "GIT_NO_REPLACE_OBJECTS" => "1",
                     "GIT_TERMINAL_PROMPT" => "0",
                     "GIT_CONFIG_PARAMETERS" => nil, "GIT_DIR" => nil, "GIT_WORK_TREE" => nil,
                     "GIT_INDEX_FILE" => nil, "GIT_OBJECT_DIRECTORY" => nil,
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil}
      stdout, stderr, status = Open3.capture3(environment, "git", "-c", "core.hooksPath=#{File::NULL}",
        "-c", "core.fsmonitor=false", "-C", @archive_root, *arguments, binmode: true)
      unless status.success?
        raise ValidationError, "git #{arguments.join(' ')} failed in #{@archive_root}: #{stderr.strip}"
      end
      stdout
    rescue Errno::ENOENT
      raise ValidationError, "git executable not found while verifying archive commit state"
    end

    # Returns a contained repository-relative artifact path; escape raises ValidationError.
    def repo_relative_path(path)
      unless within?(path, @archive_root) && path != @archive_root
        raise ValidationError, "compact artifact escapes archive root: #{path}"
      end
      Pathname.new(path).relative_path_from(Pathname.new(@archive_root)).to_s
    end
  end
end
