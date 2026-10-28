# frozen_string_literal: true

module AfEvidence
  # Owns evidence index lookup mechanics independently of pipeline policy.
  class EvidenceIndexLookup
    USER_VERSION = 1
    FILTER_KEYS = %i[
      batch_id adventure_id dimension model job_id job_key run_id status
    ].freeze
    RESULT_COLUMNS = %w[
      batch_id bundle_filename bundle_sha256 member_path byte_size member_sha256
      job_key job_id adventure_id dimension model_alias job_model status
      run_id provider run_model
    ].freeze

    attr_reader :index_path

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(index_path:)
      @index_path = existing_index_path(index_path)
    end

    # Returns deterministic locator mappings for nonempty exact lookup filters; opens SQLite read-only.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def lookup(filters = {})
      filters = normalize_filters(filters)
      raise ValidationError, "at least one evidence lookup filter is required" if filters.empty?

      database = SQLite3::Database.new(index_path, readonly: true)
      database.execute("PRAGMA query_only = ON")
      validate_index!(database)
      sql, parameters = lookup_sql(filters)
      database.execute(sql, parameters).map do |values|
        row = RESULT_COLUMNS.zip(values).to_h
        row["bundle_path"] = "#{row.fetch("batch_id")}/#{row.fetch("bundle_filename")}"
        row
      end
    rescue SQLite3::Exception => e
      raise ValidationError, "Evidence index lookup SQLite failure: #{e.message}"
    ensure
      database&.close rescue nil
    end

    private

    # Returns an existing regular non-symlink absolute derived index path.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def existing_index_path(path)
      raise ValidationError, "Evidence index path is required" if path.nil? || path.to_s.strip.empty?

      expanded = File.expand_path(path)
      raise ValidationError, "Evidence index may not be a symlink: #{expanded}" if File.symlink?(expanded)
      raise ValidationError, "Missing evidence index: #{expanded}" unless File.file?(expanded)
      expanded
    end

    # Returns supported nonblank lookup fields normalized to symbol keys.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def normalize_filters(value)
      raise ValidationError, "evidence lookup filters must be a mapping" unless value.is_a?(Hash)

      normalized = {}
      value.each do |raw_key, raw_value|
        key = raw_key.to_sym
        unless FILTER_KEYS.include?(key)
          raise ValidationError, "unknown evidence lookup filter #{raw_key.inspect}"
        end
        next if raw_value.nil?
        unless raw_value.is_a?(String) && !raw_value.strip.empty?
          raise ValidationError, "evidence lookup filter #{key} must be a nonblank string"
        end
        normalized[key] = raw_value
      end
      normalized
    end

    # Checks the opened index schema/user version before any lookup.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_index!(database)
      user_version = database.get_first_value("PRAGMA user_version")
      unless user_version == USER_VERSION
        raise ValidationError,
              "Unsupported evidence index user_version #{user_version.inspect}; expected #{USER_VERSION}"
      end

      schema_version = database.get_first_value(
        "SELECT value FROM index_metadata WHERE key = 'schema_version'"
      )
      unless schema_version == EvidenceIndexBuilder::SCHEMA_VERSION
        raise ValidationError,
              "Unsupported evidence index schema #{schema_version.inspect}; expected #{EvidenceIndexBuilder::SCHEMA_VERSION.inspect}"
      end
    rescue SQLite3::SQLException => e
      raise ValidationError, "Invalid evidence index schema: #{e.message}"
    end

    # Returns deterministic SQL and bound parameters for the normalized filters.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def lookup_sql(filters)
      clauses = []
      parameters = []
      append_filter!(clauses, parameters, filters, :batch_id, "m.batch_id")
      append_filter!(clauses, parameters, filters, :adventure_id, "j.adventure_id")
      append_filter!(clauses, parameters, filters, :dimension, "j.dimension")
      append_model_filter!(clauses, parameters, filters[:model]) if filters.key?(:model)
      append_filter!(clauses, parameters, filters, :job_id, "j.job_id")
      append_filter!(clauses, parameters, filters, :job_key, "j.job_key")
      append_filter!(clauses, parameters, filters, :run_id, "r.run_id")
      append_filter!(clauses, parameters, filters, :status, "j.status")

      sql = <<~SQL
        SELECT
          m.batch_id,
          b.bundle_filename,
          b.bundle_sha256,
          m.member_path,
          m.byte_size,
          m.sha256 AS member_sha256,
          j.job_key,
          j.job_id,
          j.adventure_id,
          j.dimension,
          j.model_alias,
          j.model AS job_model,
          j.status,
          r.run_id,
          r.provider,
          r.model AS run_model
        FROM members AS m
        JOIN batches AS b
          ON b.batch_id = m.batch_id
        LEFT JOIN jobs AS j
          ON j.batch_id = m.batch_id AND j.job_key = m.job_key
        LEFT JOIN runs AS r
          ON r.batch_id = m.batch_id AND r.run_id = m.run_id
        WHERE #{clauses.join(" AND ")}
        ORDER BY m.batch_id, m.member_path
      SQL
      [sql, parameters]
    end

    # Appends one present exact-match filter and its value to SQL clause/parameter arrays.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def append_filter!(clauses, parameters, filters, key, column)
      return unless filters.key?(key)

      clauses << "#{column} = ?"
      parameters << filters.fetch(key)
    end

    # Appends model/alias alternatives and their bound values to lookup SQL arrays.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def append_model_filter!(clauses, parameters, value)
      clauses << "(j.model = ? OR j.model_alias = ? OR r.model = ?)"
      parameters.concat([value, value, value])
    end
  end
end
