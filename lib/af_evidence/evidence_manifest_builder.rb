# frozen_string_literal: true

module AfEvidence
  # Owns evidence manifest builder mechanics independently of pipeline policy.
  class EvidenceManifestBuilder
    SCHEMA_VERSION = "af-evidence-manifest/v0.1"
    BATCH_ID_RE = /\A[a-z0-9][a-z0-9._-]*\z/
    SHA256_RE = /\A[0-9a-f]{64}\z/

    attr_reader :batch_root, :batch_id

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(batch_root:, batch_id:)
      @batch_root = expanded_batch_root(batch_root)
      @batch_id = validate_batch_id(batch_id)
    end

    # Returns the nonempty sorted path/size/raw-SHA256 inventory of the source batch.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def member_inventory(progress: nil, progress_every: 500)
      paths = canonical_file_paths
      raise ValidationError, "Evidence batch contains no canonical evidence files: #{batch_root}" if paths.empty?

      progress&.call(phase: :manifest_inventory, current: 0, total: paths.length)
      members = paths.each_with_index.map do |path, index|
        member = build_member(path)
        current = index + 1
        if current == paths.length || (progress_every.positive? && (current % progress_every).zero?)
          progress&.call(phase: :manifest_inventory, current:, total: paths.length)
        end
        member
      end
      members.sort_by { |member| member.fetch("path") }
    end

    # Returns a schema-shaped manifest from bundle metadata and optional member inventory.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build(bundle:, members: nil, progress: nil, progress_every: 500)
      members = members ? validate_member_inventory(members) : member_inventory(progress:, progress_every:)
      {
        "schema_version" => SCHEMA_VERSION,
        "batch_id" => batch_id,
        "bundle" => validate_bundle_metadata(bundle),
        "member_count" => members.length,
        "members" => members
      }
    end

    # Writes a new manifest outside the source batch and returns its normalized mapping.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def write!(output_path:, bundle:, members: nil, progress: nil, progress_every: 500)
      output = safe_output_path(output_path)
      raise ValidationError, "Evidence manifest output already exists: #{output}" if File.exist?(output)

      manifest = build(bundle:, members:, progress:, progress_every:)
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, JSON.pretty_generate(manifest) + "\n")
      manifest
    end

    private

    # Returns normalized sorted inventory rows after checking fields, hashes and unique paths.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_member_inventory(value)
      unless value.is_a?(Array) && !value.empty?
        raise ValidationError, "member inventory must be a non-empty list"
      end

      paths = {}
      normalized = value.map.with_index do |member, index|
        label = "member inventory[#{index}]"
        raise ValidationError, "#{label} must be a mapping" unless member.is_a?(Hash)
        expected = %w[path byte_size sha256]
        unless member.keys.all? { |key| key.is_a?(String) }
          raise ValidationError, "#{label} keys must be strings"
        end
        unknown = member.keys - expected
        missing = expected - member.keys
        raise ValidationError, "#{label} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
        raise ValidationError, "#{label} is missing required fields: #{missing.join(', ')}" unless missing.empty?

        path = member.fetch("path")
        validate_relative_posix_path(path, "#{label}.path")
        raise ValidationError, "member inventory contains duplicate path #{path.inspect}" if paths[path]
        paths[path] = true
        byte_size = member.fetch("byte_size")
        raise ValidationError, "#{label}.byte_size must be a non-negative integer" unless byte_size.is_a?(Integer) && byte_size >= 0
        sha256 = member.fetch("sha256")
        unless sha256.is_a?(String) && SHA256_RE.match?(sha256)
          raise ValidationError, "#{label}.sha256 must be 64 lowercase hexadecimal characters"
        end

        { "path" => path, "byte_size" => byte_size, "sha256" => sha256 }
      end
      normalized.sort_by { |member| member.fetch("path") }
    end

    # Returns the supplied member path after checking the relative POSIX path contract.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_relative_posix_path(value, label)
      unless value.is_a?(String) && !value.empty? && !value.start_with?("/") && !value.include?("\\")
        raise ValidationError, "#{label} must be a batch-relative POSIX path"
      end
      if value.split("/").any? { |part| part == "." || part == ".." }
        raise ValidationError, "#{label} may not contain . or .. path segments"
      end
      value
    end

    # Returns sorted canonical regular source paths, excluding packaging sidecars.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def canonical_file_paths
      paths = Dir.glob(File.join(batch_root, "**", "*"), File::FNM_DOTMATCH).sort
      paths.filter_map do |path|
        next if packaging_artifact?(path)

        relative = relative_posix_path(path)
        raise ValidationError, "Evidence member may not be a symlink: #{relative}" if File.symlink?(path)
        next if File.directory?(path)
        raise ValidationError, "Evidence member is not a regular file: #{relative}" unless File.file?(path)

        path
      end
    end

    # Returns whether the supplied path names excluded macOS packaging metadata.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def packaging_artifact?(path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(batch_root)).to_s
      parts = relative.split(File::SEPARATOR)
      parts.include?("__MACOSX") || parts.any? { |part| part.start_with?("._") || part == ".DS_Store" }
    end

    # Returns one source file path/size/hash record, refusing changes while reading.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build_member(path)
      before = File.stat(path)
      digest = Digest::SHA256.new
      bytes = 0
      File.open(path, "rb") do |file|
        while (chunk = file.read(1024 * 1024))
          bytes += chunk.bytesize
          digest.update(chunk)
        end
      end
      after = File.stat(path)
      unless stable_stat?(before, after) && bytes == after.size
        raise ValidationError, "Evidence member changed while hashing: #{relative_posix_path(path)}"
      end

      {
        "path" => relative_posix_path(path),
        "byte_size" => bytes,
        "sha256" => digest.hexdigest
      }
    end

    # Returns whether before/after file stats identify unchanged bytes and inode metadata.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def stable_stat?(before, after)
      before.dev == after.dev &&
        before.ino == after.ino &&
        before.size == after.size &&
        before.mtime == after.mtime &&
        before.ctime == after.ctime
    end

    # Returns or validates the source-relative POSIX member path for this owner.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def relative_posix_path(path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(batch_root)).to_s
      relative.split(File::SEPARATOR).join("/")
    end

    # Returns an existing non-symlink absolute source batch directory.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def expanded_batch_root(path)
      raise ValidationError, "Evidence batch root is required" if path.nil? || path.to_s.strip.empty?

      root = File.expand_path(path)
      raise ValidationError, "Evidence batch root does not exist: #{root}" unless Dir.exist?(root)
      raise ValidationError, "Evidence batch root may not be a symlink: #{root}" if File.symlink?(root)

      root
    end

    # Returns the supplied batch identifier after validating its portable spelling.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_batch_id(value)
      unless value.is_a?(String) && BATCH_ID_RE.match?(value)
        raise ValidationError, "batch_id must match #{BATCH_ID_RE.inspect}"
      end
      value
    end

    # Returns normalized bundle metadata after validating required fields and hashes.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_bundle_metadata(value)
      unless value.is_a?(Hash)
        raise ValidationError, "bundle metadata must be a mapping"
      end

      expected = %w[filename format profile_version byte_size sha256]
      unless value.keys.all? { |key| key.is_a?(String) }
        raise ValidationError, "bundle metadata keys must be strings"
      end
      keys = value.keys
      unknown = keys - expected
      missing = expected - keys
      raise ValidationError, "bundle metadata has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
      raise ValidationError, "bundle metadata is missing required fields: #{missing.join(', ')}" unless missing.empty?

      filename = nonblank_string(value.fetch("filename"), "bundle.filename")
      if filename == "." || filename == ".." || filename.include?("/") || filename.include?("\\")
        raise ValidationError, "bundle.filename must be a basename"
      end
      format = nonblank_string(value.fetch("format"), "bundle.format")
      profile = nonblank_string(value.fetch("profile_version"), "bundle.profile_version")
      byte_size = value.fetch("byte_size")
      raise ValidationError, "bundle.byte_size must be a positive integer" unless byte_size.is_a?(Integer) && byte_size.positive?
      sha256 = value.fetch("sha256")
      unless sha256.is_a?(String) && SHA256_RE.match?(sha256)
        raise ValidationError, "bundle.sha256 must be 64 lowercase hexadecimal characters"
      end

      {
        "filename" => filename,
        "format" => format,
        "profile_version" => profile,
        "byte_size" => byte_size,
        "sha256" => sha256
      }
    end

    # Returns the supplied named value if it is a nonblank String.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def nonblank_string(value, label)
      unless value.is_a?(String) && !value.strip.empty?
        raise ValidationError, "#{label} must be a nonblank string"
      end
      value
    end

    # Returns an absolute output path outside the supplied source/canonical root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_output_path(path)
      raise ValidationError, "Evidence manifest output path is required" if path.nil? || path.to_s.strip.empty?

      output = File.expand_path(path)
      root = Pathname.new(batch_root)
      target = Pathname.new(output)
      relative = target.relative_path_from(root).to_s
      if relative != ".." && !relative.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "Evidence manifest output must be outside the source batch: #{output}"
      end
      output
    rescue ArgumentError
      output
    end
  end
end
