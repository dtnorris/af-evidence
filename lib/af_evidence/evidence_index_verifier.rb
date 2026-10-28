# frozen_string_literal: true

module AfEvidence
  # Owns evidence index verifier mechanics independently of pipeline policy.
  class EvidenceIndexVerifier
    TABLE_QUERIES = {
      "index_metadata" => "SELECT * FROM index_metadata ORDER BY key",
      "batches" => "SELECT * FROM batches ORDER BY batch_id",
      "members" => "SELECT * FROM members ORDER BY batch_id, member_path",
      "jobs" => "SELECT * FROM jobs ORDER BY batch_id, job_key",
      "runs" => "SELECT * FROM runs ORDER BY batch_id, run_id"
    }.freeze

    Result = Struct.new(
      :index_path,
      :index_sha256,
      :batch_count,
      :member_count,
      :job_count,
      :run_count,
      keyword_init: true
    )

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(builder: EvidenceIndexBuilder.new)
      @builder = builder
    end

    # Validates the supplied canonical evidence/index against real owner checks and returns its Result.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify!(evidence_root:, index_path:)
      root = expanded_evidence_root(evidence_root)
      index = existing_index_path(index_path)
      before = stable_file_state(index, "committed evidence index")

      build_result = nil
      Dir.mktmpdir("af-evidence-index-verify-") do |tmpdir|
        rebuilt = File.join(tmpdir, "rebuilt-evidence-index.sqlite")
        build_result = @builder.build!(evidence_root: root, output_path: rebuilt)
        compare_databases!(index, rebuilt)
      end

      after = stable_file_state(index, "committed evidence index")
      unless before == after
        raise ValidationError, "committed evidence index changed during verification: #{index}"
      end

      Result.new(
        index_path: index,
        index_sha256: before.fetch(:sha256),
        batch_count: build_result.batch_count,
        member_count: build_result.member_count,
        job_count: build_result.job_count,
        run_count: build_result.run_count
      )
    rescue SQLite3::Exception => e
      raise ValidationError, "Evidence index verification SQLite failure: #{e.message}"
    end

    private

    # Compares read-only schema and logical rows of retained and freshly rebuilt indexes.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def compare_databases!(committed_path, rebuilt_path)
      committed = open_readonly(committed_path)
      rebuilt = open_readonly(rebuilt_path)
      validate_database!(committed, "committed")
      validate_database!(rebuilt, "rebuilt")

      committed_schema = schema_dump(committed)
      rebuilt_schema = schema_dump(rebuilt)
      unless committed_schema == rebuilt_schema
        raise ValidationError, "committed evidence index schema differs from deterministic rebuild"
      end

      TABLE_QUERIES.each do |table, sql|
        committed_rows = committed.execute(sql)
        rebuilt_rows = rebuilt.execute(sql)
        next if committed_rows == rebuilt_rows

        raise ValidationError,
              "committed evidence index differs from deterministic rebuild in #{table}"
      end
    ensure
      committed&.close rescue nil
      rebuilt&.close rescue nil
    end

    # Returns a query-only SQLite database for the supplied path.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def open_readonly(path)
      database = SQLite3::Database.new(path, readonly: true)
      database.execute("PRAGMA query_only = ON")
      database
    end

    # Checks integrity, foreign keys and supported versions of the named open database.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_database!(database, label)
      integrity = database.get_first_value("PRAGMA integrity_check")
      unless integrity == "ok"
        raise ValidationError, "#{label} evidence index integrity check failed: #{integrity.inspect}"
      end

      foreign_keys = database.execute("PRAGMA foreign_key_check")
      unless foreign_keys.empty?
        raise ValidationError, "#{label} evidence index foreign-key check failed"
      end

      user_version = database.get_first_value("PRAGMA user_version")
      unless user_version == EvidenceIndexLookup::USER_VERSION
        raise ValidationError,
              "#{label} evidence index user_version #{user_version.inspect} is unsupported"
      end

      schema_version = database.get_first_value(
        "SELECT value FROM index_metadata WHERE key = 'schema_version'"
      )
      unless schema_version == EvidenceIndexBuilder::SCHEMA_VERSION
        raise ValidationError,
              "#{label} evidence index schema #{schema_version.inspect} is unsupported"
      end
    rescue SQLite3::SQLException => e
      raise ValidationError, "#{label} evidence index schema is invalid: #{e.message}"
    end

    # Returns sorted non-internal SQLite schema rows for logical comparison.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def schema_dump(database)
      database.execute(<<~SQL)
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
        ORDER BY type, name
      SQL
    end

    # Returns an existing non-symlink absolute canonical evidence directory.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def expanded_evidence_root(path)
      raise ValidationError, "Evidence root is required" if path.nil? || path.to_s.strip.empty?

      root = File.expand_path(path)
      raise ValidationError, "Evidence root may not be a symlink: #{root}" if File.symlink?(root)
      raise ValidationError, "Evidence root does not exist: #{root}" unless Dir.exist?(root)
      root
    end

    # Returns an existing regular non-symlink absolute derived index path.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def existing_index_path(path)
      raise ValidationError, "Evidence index path is required" if path.nil? || path.to_s.strip.empty?

      expanded = File.expand_path(path)
      raise ValidationError, "Evidence index may not be a symlink: #{expanded}" if File.symlink?(expanded)
      raise ValidationError, "Missing evidence index: #{expanded}" unless File.file?(expanded)
      expanded
    end

    # Returns stable raw hash/stat identity of the named retained index.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def stable_file_state(path, label)
      before = File.stat(path)
      sha256 = Digest::SHA256.file(path).hexdigest
      after = File.stat(path)
      unless same_stat?(before, after)
        raise ValidationError, "#{label} changed while hashing: #{path}"
      end

      {
        dev: after.dev,
        ino: after.ino,
        size: after.size,
        mtime: after.mtime,
        ctime: after.ctime,
        sha256:
      }
    end

    # Returns whether two stat objects describe an unchanged file.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def same_stat?(left, right)
      left.dev == right.dev &&
        left.ino == right.ino &&
        left.size == right.size &&
        left.mtime == right.mtime &&
        left.ctime == right.ctime
    end
  end
end
