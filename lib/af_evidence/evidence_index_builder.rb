# frozen_string_literal: true

module AfEvidence
  # Owns evidence index builder mechanics independently of pipeline policy.
  class EvidenceIndexBuilder
    SCHEMA_VERSION = "af-evidence-index/v0.1"
    SCHEMA_PATH = File.expand_path("../../schemas/af-evidence-index-v0.1.sql", __dir__)
    MANIFEST_FILENAME = "manifest.json"
    JOB_METADATA_RE = %r{\A(.+)/runs/([^/]+)/metadata\.json\z}
    RUN_METADATA_RE = %r{\A(.+)/runs/([^/]+)/native/raw/([^/]+)/([^/]+)/run_metadata\.json\z}
    JOB_MEMBER_RE = %r{\A(.+)/runs/([^/]+)(?:/|\z)}
    RUN_MEMBER_RE = %r{\A(.+)/runs/([^/]+)/native/raw/([^/]+)/([^/]+)(?:/|\z)}
    LEGACY_LEVELS_ASSESSMENT_RE = %r{\Aassessments/(ADV-\d{4})_([^/]+)\.csv\z}
    LEGACY_LEVELS_RAW_MEMBER_RE = %r{\Araw/(ADV-\d{4})/([^/]+)(?:/|\z)}

    Result = Struct.new(
      :path,
      :batch_count,
      :member_count,
      :job_count,
      :run_count,
      keyword_init: true
    )

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(
      verifier: EvidenceBundleVerifier.new,
      decompressor: EvidenceBundleVerifier::ZstdDecompressor.new
    )
      @verifier = verifier
      @decompressor = decompressor
    end

    # Creates a new exclusive artifact from validated source evidence and returns its Result.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build!(evidence_root:, output_path:)
      root = expanded_evidence_root(evidence_root)
      output = safe_output_path(output_path, root)
      raise ValidationError, "Evidence index output already exists: #{output}" if File.exist?(output)

      manifest_paths = discover_manifests(root)
      raise ValidationError, "Evidence root contains no canonical batch manifests: #{root}" if manifest_paths.empty?

      batches = manifest_paths.map { |manifest_path| load_batch(manifest_path) }
      ensure_unique_batch_ids!(batches)

      FileUtils.mkdir_p(File.dirname(output))
      Tempfile.create([".evidence-index-", ".sqlite"], File.dirname(output)) do |temporary|
        temporary.close
        write_database!(temporary.path, batches)
        install_exclusive!(temporary.path, output)
      end

      Result.new(
        path: output,
        batch_count: batches.length,
        member_count: batches.sum { |batch| batch.fetch(:members).length },
        job_count: batches.sum { |batch| batch.fetch(:jobs).length },
        run_count: batches.sum { |batch| batch.fetch(:runs).length }
      )
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON while building evidence index: #{e.message}"
    rescue SQLite3::Exception => e
      raise ValidationError, "Evidence index SQLite failure: #{e.message}"
    end

    private

    # Returns sorted canonical batch manifest paths beneath the supplied evidence root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def discover_manifests(root)
      Dir.glob(File.join(root, "*", MANIFEST_FILENAME)).select { |path| File.file?(path) }.sort
    end

    # Returns a verified batch with canonical members and interpreted AFIO/legacy records.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def load_batch(manifest_path)
      manifest = JSON.parse(File.binread(manifest_path))
      raise ValidationError, "evidence manifest must be a mapping: #{manifest_path}" unless manifest.is_a?(Hash)

      batch_id = nonblank_string(manifest["batch_id"], "manifest batch_id")
      unless File.basename(File.dirname(manifest_path)) == batch_id
        raise ValidationError,
              "evidence batch directory must match manifest batch_id: #{File.dirname(manifest_path)}"
      end

      bundle = manifest["bundle"]
      raise ValidationError, "manifest bundle must be a mapping: #{manifest_path}" unless bundle.is_a?(Hash)
      bundle_filename = basename_string(bundle["filename"], "manifest bundle.filename")
      bundle_path = File.join(File.dirname(manifest_path), bundle_filename)

      @verifier.verify!(manifest_path:, bundle_path:)
      records = read_index_records(bundle_path:, batch_id:)
      verify_bundle_still_matches!(bundle_path, manifest.fetch("bundle"))
      members = build_members(manifest.fetch("members"), records.fetch(:jobs), records.fetch(:runs))

      {
        batch_id:,
        manifest_schema_version: manifest.fetch("schema_version"),
        manifest_sha256: Digest::SHA256.file(manifest_path).hexdigest,
        bundle: manifest.fetch("bundle"),
        declared_member_count: manifest.fetch("member_count"),
        members:,
        jobs: records.fetch(:jobs).values.sort_by { |job| job.fetch(:job_key) },
        runs: records.fetch(:runs).values.sort_by { |run| run.fetch(:run_id) }
      }
    end

    # Returns job/run mappings read from a verified bundle without interpreting workload state.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def read_index_records(bundle_path:, batch_id:)
      jobs = {}
      raw_runs = []
      legacy_levels_assessments = []

      Tempfile.create(["af-evidence-index-", ".tar"]) do |tar_file|
        tar_file.close
        @decompressor.decompress!(bundle_path:, output_path: tar_file.path)
        File.open(tar_file.path, "rb") do |io|
          Gem::Package::TarReader.new(io) do |tar|
            tar.each do |entry|
              next unless entry.file?

              path = entry.full_name
              if (match = JOB_METADATA_RE.match(path))
                job = parse_job_metadata(entry.read, path, match[1], match[2], batch_id)
                duplicate_record!(jobs, job.fetch(:job_key), "job_key")
                jobs[job.fetch(:job_key)] = job
              elsif (match = RUN_METADATA_RE.match(path))
                raw_runs << parse_run_metadata(entry.read, path, match[1], match[2], match[3], match[4], batch_id)
              elsif (match = LEGACY_LEVELS_ASSESSMENT_RE.match(path))
                legacy_levels_assessments << parse_legacy_levels_assessment(
                  entry.read, path, match[1], match[2], batch_id
                )
              end
            end
          end
        end
      end

      if jobs.empty? && !legacy_levels_assessments.empty?
        return build_legacy_levels_records!(legacy_levels_assessments)
      end
      if jobs.empty?
        raise ValidationError,
              "verified evidence batch #{batch_id.inspect} contains no recognizable AFIO job metadata"
      end
      unless legacy_levels_assessments.empty?
        raise ValidationError,
              "verified evidence batch #{batch_id.inspect} mixes AFIO metadata with legacy flat Levels assessments"
      end

      runs = {}
      raw_runs.each do |run|
        job = jobs[run.fetch(:job_key)]
        unless job
          raise ValidationError,
                "native run #{run.fetch(:run_id).inspect} references missing job #{run.fetch(:job_key).inspect}"
        end
        cross_check_run!(job, run)
        duplicate_record!(runs, run.fetch(:run_id), "run_id")
        runs[run.fetch(:run_id)] = run
      end

      { jobs:, runs: }
    rescue Gem::Package::TarInvalidError, EOFError => e
      raise ValidationError, "Invalid verified evidence tar stream while indexing: #{e.message}"
    end

    # Returns legacy Levels job/run records from CSV bytes and bound path identifiers.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def parse_legacy_levels_assessment(bytes, member_path, path_adventure_id, path_run_id, batch_id)
      table = CSV.parse(bytes, headers: true)
      required_headers = %w[
        run_id status adventure_id afao_version assessment_spec_version
        provider model source_scope group metric_kind metric
      ]
      missing_headers = required_headers - Array(table.headers)
      unless missing_headers.empty?
        raise ValidationError,
              "#{member_path} legacy Levels assessment is missing headers: #{missing_headers.join(', ')}"
      end

      rows = table.map(&:to_h)
      raise ValidationError, "#{member_path} legacy Levels assessment contains no rows" if rows.empty?

      run_id = legacy_consistent_field!(rows, "run_id", member_path)
      adventure_id = legacy_consistent_field!(rows, "adventure_id", member_path)
      status = legacy_consistent_field!(rows, "status", member_path)
      provider = legacy_consistent_field!(rows, "provider", member_path)
      model = legacy_consistent_field!(rows, "model", member_path)
      afao_version = legacy_consistent_field!(rows, "afao_version", member_path)
      assessment_spec_version = legacy_consistent_field!(rows, "assessment_spec_version", member_path)
      source_scope = legacy_consistent_field!(rows, "source_scope", member_path)
      group = legacy_consistent_field!(rows, "group", member_path)
      metric_kind = legacy_consistent_field!(rows, "metric_kind", member_path)

      unless adventure_id == path_adventure_id
        raise ValidationError,
              "#{member_path} legacy Levels filename/CSV adventure mismatch: " \
              "filename=#{path_adventure_id.inspect} csv=#{adventure_id.inspect}"
      end
      unless run_id == path_run_id
        raise ValidationError,
              "#{member_path} legacy Levels filename/CSV run_id mismatch: " \
              "filename=#{path_run_id.inspect} csv=#{run_id.inspect}"
      end
      unless group == "sessions_levels" && metric_kind == "level"
        raise ValidationError,
              "#{member_path} is not the supported legacy flat Levels assessment shape"
      end

      metrics = rows.map { |row| row["metric"] }.sort
      unless metrics == ["Level End", "Level Start"]
        raise ValidationError,
              "#{member_path} legacy Levels assessment must contain exactly Level Start and Level End"
      end

      job_key = "raw/#{adventure_id}/#{run_id}"
      job = {
        batch_id:,
        job_key:,
        job_id: run_id,
        adventure_id:,
        dimension: "Levels",
        model_alias: nil,
        model:,
        status:,
        replicate: nil,
        worker: nil,
        started_at: nil,
        completed_at: nil,
        elapsed_seconds: nil,
        exit_status: nil,
        estimated_cost_usd: nil,
        metadata_member_path: member_path
      }
      run = {
        batch_id:,
        run_id:,
        job_key:,
        job_id: run_id,
        adventure_id:,
        dimension: "Levels",
        provider:,
        model:,
        prompt_profile: nil,
        afao_version:,
        assessment_spec_version:,
        reasoning_effort: nil,
        source_scope:,
        experimental: nil,
        run_metadata_member_path: member_path
      }
      { job:, run: }
    rescue CSV::MalformedCSVError => e
      raise ValidationError, "Invalid legacy Levels assessment CSV #{member_path}: #{e.message}"
    end

    # Returns the unique nonblank field shared by all supplied legacy CSV rows.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def legacy_consistent_field!(rows, field, member_path)
      values = rows.map { |row| row[field] }.uniq
      unless values.length == 1
        raise ValidationError,
              "#{member_path} legacy Levels rows disagree on #{field}: #{values.inspect}"
      end
      nonblank_string(values.fetch(0), "#{member_path} #{field}")
    end

    # Returns unique legacy job/run mappings from parsed assessment records.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build_legacy_levels_records!(assessments)
      jobs = {}
      runs = {}
      assessments.each do |assessment|
        job = assessment.fetch(:job)
        run = assessment.fetch(:run)
        duplicate_record!(jobs, job.fetch(:job_key), "job_key")
        duplicate_record!(runs, run.fetch(:run_id), "run_id")
        jobs[job.fetch(:job_key)] = job
        runs[run.fetch(:run_id)] = run
      end
      { jobs:, runs: }
    end

    # Returns an AFIO job record from JSON bytes cross-checked against its member path.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def parse_job_metadata(bytes, member_path, experiment_path, path_job_id, batch_id)
      data = parse_json_mapping(bytes, member_path)
      job_id = nonblank_string(data["job_id"], "#{member_path} job_id")
      unless job_id == path_job_id
        raise ValidationError,
              "job metadata path/id mismatch: path=#{path_job_id.inspect} metadata=#{job_id.inspect}"
      end

      {
        batch_id:,
        job_key: "#{experiment_path}/runs/#{job_id}",
        job_id:,
        adventure_id: nonblank_string(data["adventure"], "#{member_path} adventure"),
        dimension: nonblank_string(data["dimension"], "#{member_path} dimension"),
        model_alias: optional_string(data["model_alias"], "#{member_path} model_alias"),
        model: optional_string(data["ollama_model"], "#{member_path} ollama_model"),
        status: nonblank_string(data["status"], "#{member_path} status"),
        replicate: optional_integer(data["replicate"], "#{member_path} replicate"),
        worker: optional_string(data["worker"], "#{member_path} worker"),
        started_at: optional_string(data["started_at"], "#{member_path} started_at"),
        completed_at: optional_string(data["completed_at"], "#{member_path} completed_at"),
        elapsed_seconds: optional_number(data["elapsed_seconds"], "#{member_path} elapsed_seconds"),
        exit_status: optional_integer(data["exit_status"], "#{member_path} exit_status"),
        estimated_cost_usd: optional_number(data["estimated_cost_usd"], "#{member_path} estimated_cost_usd"),
        metadata_member_path: member_path
      }
    end

    # Returns a native run record from JSON bytes cross-checked against path identifiers.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def parse_run_metadata(bytes, member_path, experiment_path, job_id, path_adventure_id, path_run_id, batch_id)
      data = parse_json_mapping(bytes, member_path)
      run_id = nonblank_string(data["run_id"], "#{member_path} run_id")
      adventure_id = nonblank_string(data["adventure_id"], "#{member_path} adventure_id")
      unless run_id == path_run_id
        raise ValidationError,
              "run metadata path/id mismatch: path=#{path_run_id.inspect} metadata=#{run_id.inspect}"
      end
      unless adventure_id == path_adventure_id
        raise ValidationError,
              "run metadata adventure path/id mismatch: path=#{path_adventure_id.inspect} metadata=#{adventure_id.inspect}"
      end

      {
        batch_id:,
        run_id:,
        job_key: "#{experiment_path}/runs/#{job_id}",
        job_id:,
        adventure_id:,
        dimension: nonblank_string(data["selected_dimension"], "#{member_path} selected_dimension"),
        provider: optional_string(data["provider"], "#{member_path} provider"),
        model: optional_string(data["model"], "#{member_path} model"),
        prompt_profile: optional_string(data["prompt_profile"], "#{member_path} prompt_profile"),
        afao_version: optional_string(data["afao_version"], "#{member_path} afao_version"),
        assessment_spec_version: optional_string(data["assessment_spec_version"], "#{member_path} assessment_spec_version"),
        reasoning_effort: optional_string(data["reasoning_effort"], "#{member_path} reasoning_effort"),
        source_scope: optional_string(data["source_scope"], "#{member_path} source_scope"),
        experimental: optional_boolean_integer(data["experimental"], "#{member_path} experimental"),
        run_metadata_member_path: member_path
      }
    end

    # Checks shared adventure/dimension/model fields between a job and native run.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def cross_check_run!(job, run)
      {
        adventure_id: "adventure",
        dimension: "dimension",
        model: "model"
      }.each do |field, label|
        job_value = job[field]
        run_value = run[field]
        next if job_value.nil? || run_value.nil? || job_value == run_value

        raise ValidationError,
              "job/run #{label} mismatch for #{job.fetch(:job_key)}: job=#{job_value.inspect} run=#{run_value.inspect}"
      end
    end

    # Returns sorted canonical member rows bound to recognizable jobs and native runs.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build_members(raw_members, jobs, runs)
      members = raw_members.map do |member|
        path = member.fetch("path")
        job_match = JOB_MEMBER_RE.match(path)
        job_key = nil
        run_id = nil

        if job_match
          job_key = "#{job_match[1]}/runs/#{job_match[2]}"
          unless jobs.key?(job_key)
            raise ValidationError,
                  "evidence member #{path.inspect} references missing job metadata #{job_key.inspect}"
          end
          run_id = RUN_MEMBER_RE.match(path)&.[](4)
          run_id = nil unless run_id && runs.key?(run_id)
        elsif (legacy = legacy_member_identity(path))
          adventure_id, legacy_run_id = legacy
          legacy_job_key = "raw/#{adventure_id}/#{legacy_run_id}"
          if jobs.key?(legacy_job_key)
            job_key = legacy_job_key
            run_id = legacy_run_id if runs.key?(legacy_run_id)
          end
        end

        {
          member_path: path,
          byte_size: member.fetch("byte_size"),
          sha256: member.fetch("sha256"),
          job_key:,
          run_id:
        }
      end

      legacy_job_keys = jobs.keys.select { |job_key| job_key.start_with?("raw/") }
      member_paths = members.to_h { |member| [member.fetch(:member_path), true] }
      legacy_job_keys.each do |job_key|
        required = [
          "#{job_key}/dimension_levels.json",
          "#{job_key}/dimension_levels_request.json"
        ]
        missing = required.reject { |path| member_paths[path] }
        next if missing.empty?

        raise ValidationError,
              "legacy flat Levels job #{job_key.inspect} is missing raw evidence: #{missing.join(', ')}"
      end

      members.sort_by { |member| member.fetch(:member_path) }
    end

    # Returns legacy adventure/run identifiers from a supported path, or nil.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def legacy_member_identity(path)
      if (match = LEGACY_LEVELS_ASSESSMENT_RE.match(path))
        return [match[1], match[2]]
      end
      if (match = LEGACY_LEVELS_RAW_MEMBER_RE.match(path))
        return [match[1], match[2]]
      end
      nil
    end

    # Writes derived schema and sorted records, checking integrity and foreign keys.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def write_database!(path, batches)
      database = SQLite3::Database.new(path)
      database.execute_batch(File.read(SCHEMA_PATH))
      database.transaction do
        database.execute("INSERT INTO index_metadata(key, value) VALUES (?, ?)", ["schema_version", SCHEMA_VERSION])
        database.execute(
          "INSERT INTO index_metadata(key, value) VALUES (?, ?)",
          ["manifest_schema_version", EvidenceManifestBuilder::SCHEMA_VERSION]
        )
        batches.sort_by { |batch| batch.fetch(:batch_id) }.each do |batch|
          insert_batch!(database, batch)
        end
      end
      foreign_key_errors = database.execute("PRAGMA foreign_key_check")
      raise ValidationError, "Evidence index foreign-key check failed" unless foreign_key_errors.empty?
      integrity = database.get_first_value("PRAGMA integrity_check")
      raise ValidationError, "Evidence index integrity check failed: #{integrity.inspect}" unless integrity == "ok"
      database.close
      File.chmod(0o644, path)
    ensure
      database&.close rescue nil
    end

    # Inserts the supplied batch and its members, jobs and runs into the derived database.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def insert_batch!(database, batch)
      bundle = batch.fetch(:bundle)
      database.execute(
        <<~SQL,
          INSERT INTO batches(
            batch_id, manifest_schema_version, manifest_sha256,
            bundle_filename, bundle_format, bundle_profile_version,
            bundle_byte_size, bundle_sha256, member_count
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          batch.fetch(:batch_id), batch.fetch(:manifest_schema_version), batch.fetch(:manifest_sha256),
          bundle.fetch("filename"), bundle.fetch("format"), bundle.fetch("profile_version"),
          bundle.fetch("byte_size"), bundle.fetch("sha256"), batch.fetch(:declared_member_count)
        ]
      )

      batch.fetch(:members).each do |member|
        database.execute(
          "INSERT INTO members(batch_id, member_path, byte_size, sha256, job_key, run_id) VALUES (?, ?, ?, ?, ?, ?)",
          [batch.fetch(:batch_id), member.fetch(:member_path), member.fetch(:byte_size), member.fetch(:sha256), member[:job_key], member[:run_id]]
        )
      end
      batch.fetch(:jobs).each { |job| insert_job!(database, batch.fetch(:batch_id), job) }
      batch.fetch(:runs).each { |run| insert_run!(database, batch.fetch(:batch_id), run) }
    end

    # Inserts one supplied AFIO/legacy job record bound to the batch identifier.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def insert_job!(database, batch_id, job)
      database.execute(
        <<~SQL,
          INSERT INTO jobs(
            batch_id, job_key, job_id, adventure_id, dimension, model_alias, model, status,
            replicate, worker, started_at, completed_at, elapsed_seconds, exit_status,
            estimated_cost_usd, metadata_member_path
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          batch_id, job.fetch(:job_key), job.fetch(:job_id), job.fetch(:adventure_id), job.fetch(:dimension), job[:model_alias], job[:model],
          job.fetch(:status), job[:replicate], job[:worker], job[:started_at], job[:completed_at], job[:elapsed_seconds],
          job[:exit_status], job[:estimated_cost_usd], job.fetch(:metadata_member_path)
        ]
      )
    end

    # Inserts one supplied native/legacy run record bound to the batch identifier.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def insert_run!(database, batch_id, run)
      database.execute(
        <<~SQL,
          INSERT INTO runs(
            batch_id, run_id, job_key, job_id, adventure_id, dimension, provider, model,
            prompt_profile, afao_version, assessment_spec_version, reasoning_effort,
            source_scope, experimental, run_metadata_member_path
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          batch_id, run.fetch(:run_id), run.fetch(:job_key), run.fetch(:job_id), run.fetch(:adventure_id), run.fetch(:dimension),
          run[:provider], run[:model], run[:prompt_profile], run[:afao_version], run[:assessment_spec_version],
          run[:reasoning_effort], run[:source_scope], run[:experimental], run.fetch(:run_metadata_member_path)
        ]
      )
    end

    # Rechecks stable bundle bytes after indexing against the supplied declared hash/size.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_bundle_still_matches!(path, bundle)
      before = File.stat(path)
      actual_sha256 = Digest::SHA256.file(path).hexdigest
      after = File.stat(path)
      unless before.dev == after.dev && before.ino == after.ino && before.size == after.size &&
             before.mtime == after.mtime && before.ctime == after.ctime
        raise ValidationError, "evidence bundle changed while indexing: #{path}"
      end
      unless after.size == bundle.fetch("byte_size") && actual_sha256 == bundle.fetch("sha256")
        raise ValidationError, "evidence bundle changed after verification: #{path}"
      end
    end

    # Returns a mapping parsed from named JSON bytes.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def parse_json_mapping(bytes, label)
      value = JSON.parse(bytes)
      raise ValidationError, "#{label} must contain a JSON mapping" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON in #{label}: #{e.message}"
    end

    # Checks that the supplied verified batches have distinct canonical identities.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def ensure_unique_batch_ids!(batches)
      duplicates = batches.group_by { |batch| batch.fetch(:batch_id) }.select { |_id, items| items.length > 1 }.keys
      return if duplicates.empty?
      raise ValidationError, "duplicate evidence batch_id values: #{duplicates.sort.join(', ')}"
    end

    # Refuses a record key already present in the supplied job/run mapping.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def duplicate_record!(records, key, label)
      raise ValidationError, "duplicate evidence #{label} #{key.inspect}" if records.key?(key)
    end

    # Returns the supplied named value if it is a nonblank String.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def nonblank_string(value, label)
      unless value.is_a?(String) && !value.strip.empty?
        raise ValidationError, "#{label} must be a nonblank string"
      end
      value
    end

    # Returns nil or a validated nonblank String for the named optional field.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def optional_string(value, label)
      return nil if value.nil?
      nonblank_string(value, label)
    end

    # Returns nil or an Integer for the named optional field.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def optional_integer(value, label)
      return nil if value.nil?
      raise ValidationError, "#{label} must be an integer" unless value.is_a?(Integer)
      value
    end

    # Returns nil or a Numeric value for the named optional field.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def optional_number(value, label)
      return nil if value.nil?
      raise ValidationError, "#{label} must be numeric" unless value.is_a?(Numeric)
      value
    end

    # Returns nil, 1 or 0 for a supplied optional boolean.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def optional_boolean_integer(value, label)
      return nil if value.nil?
      return value ? 1 : 0 if value == true || value == false
      raise ValidationError, "#{label} must be boolean"
    end

    # Returns a nonblank basename with no directory or backslash components.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def basename_string(value, label)
      value = nonblank_string(value, label)
      if value != File.basename(value) || value.include?("\\") || [".", ".."].include?(value)
        raise ValidationError, "#{label} must be a basename"
      end
      value
    end

    # Returns an existing non-symlink absolute canonical evidence directory.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def expanded_evidence_root(path)
      raise ValidationError, "Evidence root is required" if path.nil? || path.to_s.strip.empty?
      root = File.expand_path(path)
      raise ValidationError, "Evidence root does not exist: #{root}" unless Dir.exist?(root)
      raise ValidationError, "Evidence root may not be a symlink: #{root}" if File.symlink?(root)
      root
    end

    # Returns an absolute output path outside the supplied source/canonical root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_output_path(path, root)
      raise ValidationError, "Evidence index output path is required" if path.nil? || path.to_s.strip.empty?
      output = File.expand_path(path)
      relation = Pathname.new(output).relative_path_from(Pathname.new(root)).to_s
      if relation != ".." && !relation.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "Evidence index output must be outside the canonical evidence root: #{output}"
      end
      output
    rescue ArgumentError
      output
    end

    # Copies source bytes exclusively to destination; removes only its incomplete new file.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def install_exclusive!(source, destination)
      created = false
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |output|
        created = true
        File.open(source, "rb") { |input| IO.copy_stream(input, output) }
        output.flush
        output.fsync
      end
    rescue Errno::EEXIST
      raise ValidationError, "Evidence index output already exists: #{destination}"
    rescue StandardError
      FileUtils.rm_f(destination) if created
      raise
    end
  end
end
