# frozen_string_literal: true

module AfEvidence
  # Owns evidence bundle verifier mechanics independently of pipeline policy.
  class EvidenceBundleVerifier
    SCHEMA_VERSION = "af-evidence-manifest/v0.1"
    BATCH_ID_RE = /\A[a-z0-9][a-z0-9._-]*\z/
    SHA256_RE = /\A[0-9a-f]{64}\z/

    Result = Struct.new(
      :manifest_path,
      :bundle_path,
      :batch_id,
      :member_count,
      :bundle_sha256,
      :source_verified,
      keyword_init: true
    )

    # External zstd process boundary; no provider or workflow execution.
    class ZstdDecompressor
      # Binds the supplied paths and collaborators for later calls; returns the instance.
      # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
      def initialize(command: ENV.fetch("AF_EVIDENCE_ZSTD", "zstd"))
        @command = command
      end

      # Decompresses bundle_path into output_path using existing zstd; returns nil on success.
      # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
      def decompress!(bundle_path:, output_path:)
        _stdout, stderr, status = Open3.capture3(
          @command,
          "-q",
          "-d",
          "-f",
          "-o",
          output_path,
          bundle_path
        )
        return if status.success?

        detail = stderr.to_s.strip
        detail = "exit #{status.exitstatus}" if detail.empty?
        raise ValidationError, "zstd decompression failed: #{detail}"
      rescue Errno::ENOENT
        raise ValidationError,
              "zstd decompressor not found: #{@command.inspect}; install zstd or set AF_EVIDENCE_ZSTD"
      end
    end

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(decompressor: ZstdDecompressor.new)
      @decompressor = decompressor
    end

    # Validates the supplied canonical evidence/index against real owner checks and returns its Result.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify!(manifest_path:, bundle_path:, source_root: nil)
      manifest_path = existing_regular_file!(manifest_path, "evidence manifest")
      bundle_path = existing_regular_file!(bundle_path, "evidence bundle")
      manifest = load_manifest(manifest_path)
      members = validate_manifest!(manifest, bundle_path)
      verify_bundle_bytes!(manifest.fetch("bundle"), bundle_path)

      Tempfile.create(["af-evidence-verify-", ".tar"]) do |tar_file|
        tar_file.close
        @decompressor.decompress!(bundle_path:, output_path: tar_file.path)
        unless File.file?(tar_file.path) && File.size(tar_file.path).positive?
          raise ValidationError, "zstd decompressor produced no tar bytes"
        end

        Dir.mktmpdir("af-evidence-round-trip-") do |extract_root|
          verify_tar_and_extract!(tar_file.path, members, extract_root)
          verify_source!(source_root, members) if source_root
        end
      end

      Result.new(
        manifest_path:,
        bundle_path:,
        batch_id: manifest.fetch("batch_id"),
        member_count: members.length,
        bundle_sha256: manifest.dig("bundle", "sha256"),
        source_verified: !source_root.nil?
      )
    rescue JSON::ParserError => e
      raise ValidationError, "Invalid JSON in evidence manifest #{manifest_path}: #{e.message}"
    rescue Gem::Package::TarInvalidError, EOFError => e
      raise ValidationError, "Invalid evidence tar stream: #{e.message}"
    end

    private

    # Parses the supplied JSON file and returns a manifest mapping.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def load_manifest(path)
      parsed = JSON.parse(File.binread(path))
      raise ValidationError, "evidence manifest must be a mapping" unless parsed.is_a?(Hash)

      parsed
    end

    # Returns unique ordered manifest members after validating manifest and bundle identity.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_manifest!(manifest, bundle_path)
      exact_keys!(manifest, %w[schema_version batch_id bundle member_count members], "evidence manifest")
      require_keys!(manifest, %w[schema_version batch_id bundle member_count members], "evidence manifest")
      unless manifest.fetch("schema_version") == SCHEMA_VERSION
        raise ValidationError,
              "Unsupported evidence manifest schema #{manifest['schema_version'].inspect}; expected #{SCHEMA_VERSION.inspect}"
      end

      batch_id = manifest.fetch("batch_id")
      unless batch_id.is_a?(String) && BATCH_ID_RE.match?(batch_id)
        raise ValidationError, "evidence manifest batch_id is invalid"
      end

      validate_bundle_manifest!(manifest.fetch("bundle"), bundle_path)
      raw_members = manifest.fetch("members")
      unless raw_members.is_a?(Array) && !raw_members.empty?
        raise ValidationError, "evidence manifest members must be a non-empty list"
      end
      count = manifest.fetch("member_count")
      unless count.is_a?(Integer) && count.positive? && count == raw_members.length
        raise ValidationError, "evidence manifest member_count must equal members.length"
      end

      by_path = {}
      raw_members.each_with_index do |member, index|
        label = "evidence manifest members[#{index}]"
        raise ValidationError, "#{label} must be a mapping" unless member.is_a?(Hash)
        exact_keys!(member, %w[path byte_size sha256], label)
        require_keys!(member, %w[path byte_size sha256], label)

        path = validate_relative_posix_path(member.fetch("path"), "#{label}.path")
        raise ValidationError, "evidence manifest contains duplicate member path #{path.inspect}" if by_path.key?(path)

        byte_size = member.fetch("byte_size")
        unless byte_size.is_a?(Integer) && byte_size >= 0
          raise ValidationError, "#{label}.byte_size must be a non-negative integer"
        end
        sha256 = member.fetch("sha256")
        unless sha256.is_a?(String) && SHA256_RE.match?(sha256)
          raise ValidationError, "#{label}.sha256 must be 64 lowercase hexadecimal characters"
        end
        by_path[path] = { "path" => path, "byte_size" => byte_size, "sha256" => sha256 }
      end
      unless by_path.keys == by_path.keys.sort
        raise ValidationError, "evidence manifest members are not in canonical lexicographic order"
      end
      by_path
    end

    # Checks bundle metadata and filename against the actual supplied path; returns nil.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_bundle_manifest!(bundle, bundle_path)
      raise ValidationError, "evidence manifest bundle must be a mapping" unless bundle.is_a?(Hash)
      exact_keys!(bundle, %w[filename format profile_version byte_size sha256], "evidence manifest bundle")
      require_keys!(bundle, %w[filename format profile_version byte_size sha256], "evidence manifest bundle")

      filename = bundle.fetch("filename")
      unless filename.is_a?(String) && filename == File.basename(filename) &&
             !filename.include?("\\") && ![".", ".."].include?(filename)
        raise ValidationError, "evidence manifest bundle.filename must be a basename"
      end
      unless filename.end_with?(".tar.zst")
        raise ValidationError, "evidence manifest bundle.filename must end in .tar.zst"
      end
      unless filename == File.basename(bundle_path)
        raise ValidationError,
              "evidence manifest bundle filename mismatch: manifest=#{filename.inspect} actual=#{File.basename(bundle_path).inspect}"
      end
      unless bundle.fetch("format") == EvidenceBundleBuilder::FORMAT
        raise ValidationError, "unsupported evidence bundle format #{bundle['format'].inspect}"
      end
      unless bundle.fetch("profile_version") == EvidenceBundleBuilder::PROFILE_VERSION
        raise ValidationError, "unsupported evidence bundle profile #{bundle['profile_version'].inspect}"
      end
      byte_size = bundle.fetch("byte_size")
      raise ValidationError, "evidence manifest bundle.byte_size must be a positive integer" unless byte_size.is_a?(Integer) && byte_size.positive?
      sha256 = bundle.fetch("sha256")
      unless sha256.is_a?(String) && SHA256_RE.match?(sha256)
        raise ValidationError, "evidence manifest bundle.sha256 must be 64 lowercase hexadecimal characters"
      end
    end

    # Checks stable bundle size and raw hash against declared metadata.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_bundle_bytes!(bundle, bundle_path)
      actual = hash_file_stably(bundle_path, "evidence bundle")
      unless actual.fetch("byte_size") == bundle.fetch("byte_size")
        raise ValidationError,
              "evidence bundle byte size mismatch: manifest=#{bundle.fetch('byte_size')} actual=#{actual.fetch('byte_size')}"
      end
      unless actual.fetch("sha256") == bundle.fetch("sha256")
        raise ValidationError,
              "evidence bundle sha256 mismatch: manifest=#{bundle.fetch('sha256')} actual=#{actual.fetch('sha256')}"
      end
    end

    # Verifies exact regular tar members against the inventory while extracting to scratch.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_tar_and_extract!(tar_path, expected, extract_root)
      verify_tar_envelope!(tar_path, expected)
      seen = {}
      order = []
      File.open(tar_path, "rb") do |io|
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            path = validate_relative_posix_path(entry.full_name, "tar member path")
            raise ValidationError, "evidence bundle contains duplicate member #{path.inspect}" if seen.key?(path)
            raise ValidationError, "evidence bundle contains undeclared member #{path.inspect}" unless expected.key?(path)
            unless entry.file?
              raise ValidationError, "evidence bundle member is not a regular file: #{path}"
            end
            verify_tar_metadata!(entry, path)

            declared = expected.fetch(path)
            unless entry.header.size == declared.fetch("byte_size")
              raise ValidationError,
                    "evidence bundle member size mismatch for #{path}: manifest=#{declared.fetch('byte_size')} tar=#{entry.header.size}"
            end

            extracted = safe_extraction_path(extract_root, path)
            FileUtils.mkdir_p(File.dirname(extracted))
            digest = Digest::SHA256.new
            bytes = 0
            File.open(extracted, "wb") do |output|
              while (chunk = entry.read(1024 * 1024)) && !chunk.empty?
                bytes += chunk.bytesize
                digest.update(chunk)
                output.write(chunk)
              end
            end
            unless bytes == declared.fetch("byte_size") && digest.hexdigest == declared.fetch("sha256")
              raise ValidationError, "evidence bundle member hash mismatch for #{path}"
            end
            unless File.size(extracted) == declared.fetch("byte_size") && Digest::SHA256.file(extracted).hexdigest == declared.fetch("sha256")
              raise ValidationError, "round-trip extraction verification failed for #{path}"
            end

            seen[path] = true
            order << path
          end
        end
      end

      missing = expected.keys - seen.keys
      raise ValidationError, "evidence bundle is missing manifest members: #{missing.join(', ')}" unless missing.empty?
      canonical_order = expected.keys.sort
      unless order == canonical_order
        raise ValidationError, "evidence bundle members are not in canonical lexicographic order"
      end
    end


    # Checks the exact normalized tar byte length and two end-of-archive blocks.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_tar_envelope!(tar_path, expected)
      expected_size = expected.values.sum do |member|
        size = member.fetch("byte_size")
        512 + size + ((512 - (size % 512)) % 512)
      end + 1024
      actual_size = File.size(tar_path)
      unless actual_size == expected_size
        raise ValidationError,
              "evidence tar byte size mismatch: expected=#{expected_size} actual=#{actual_size}"
      end

      File.open(tar_path, "rb") do |io|
        io.seek(-1024, IO::SEEK_END)
        unless io.read(1024) == ("\0" * 1024)
          raise ValidationError, "evidence tar is missing the canonical end-of-archive blocks"
        end
      end
    end

    # Checks the supplied tar entry against frozen mode, owner and timestamp metadata.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_tar_metadata!(entry, path)
      header = entry.header
      unless header.mode == EvidenceBundleBuilder::TAR_MODE &&
             header.uid.zero? && header.gid.zero? && header.mtime.zero? &&
             header.uname.to_s.empty? && header.gname.to_s.empty?
        raise ValidationError, "evidence bundle member has non-canonical tar metadata: #{path}"
      end
    end

    # Checks the expanded source inventory against every declared canonical member.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_source!(source_root, expected)
      root = expanded_source_root(source_root)
      observed = {}
      paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      paths.each do |path|
        next if packaging_artifact?(root, path)

        relative = relative_posix_path(root, path)
        raise ValidationError, "source evidence member may not be a symlink: #{relative}" if File.symlink?(path)
        next if File.directory?(path)
        raise ValidationError, "source evidence member is not a regular file: #{relative}" unless File.file?(path)

        observed[relative] = hash_file_stably(path, "source evidence member #{relative}")
      end

      missing = expected.keys - observed.keys
      extra = observed.keys - expected.keys
      unless missing.empty? && extra.empty?
        raise ValidationError,
              "source evidence set mismatch: missing=#{missing.sort.inspect} extra=#{extra.sort.inspect}"
      end
      expected.each do |path, declared|
        actual = observed.fetch(path)
        unless actual.fetch("byte_size") == declared.fetch("byte_size")
          raise ValidationError,
                "source member byte size mismatch for #{path}: manifest=#{declared.fetch('byte_size')} actual=#{actual.fetch('byte_size')}"
        end
        unless actual.fetch("sha256") == declared.fetch("sha256")
          raise ValidationError,
                "source member sha256 mismatch for #{path}: manifest=#{declared.fetch('sha256')} actual=#{actual.fetch('sha256')}"
        end
      end
    end

    # Returns whether the supplied path names excluded macOS packaging metadata.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def packaging_artifact?(root, path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      parts = relative.split(File::SEPARATOR)
      parts.include?("__MACOSX") || parts.any? { |part| part.start_with?("._") || part == ".DS_Store" }
    end

    # Returns or validates the source-relative POSIX member path for this owner.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def relative_posix_path(root, path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      relative.split(File::SEPARATOR).join("/")
    end

    # Returns the supplied member path after checking the relative POSIX path contract.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_relative_posix_path(value, label)
      unless value.is_a?(String) && !value.empty? && !value.start_with?("/") && !value.include?("\\")
        raise ValidationError, "#{label} must be a batch-relative POSIX path"
      end
      parts = value.split("/")
      if parts.any? { |part| part.empty? || part == "." || part == ".." }
        raise ValidationError, "#{label} contains an unsafe path segment"
      end
      if parts.include?("__MACOSX") || parts.any? { |part| part.start_with?("._") || part == ".DS_Store" }
        raise ValidationError, "#{label} names excluded packaging metadata"
      end
      value
    end

    # Returns an absolute scratch destination contained beneath the supplied root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_extraction_path(root, relative)
      candidate = File.expand_path(relative.split("/").join(File::SEPARATOR), root)
      relation = Pathname.new(candidate).relative_path_from(Pathname.new(root)).to_s
      if relation == ".." || relation.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "evidence bundle member escapes extraction root: #{relative}"
      end
      candidate
    rescue ArgumentError
      raise ValidationError, "evidence bundle member escapes extraction root: #{relative}"
    end

    # Returns a file size/hash mapping, refusing source changes during the read.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def hash_file_stably(path, label)
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
      unless before.dev == after.dev && before.ino == after.ino &&
             before.size == after.size && before.mtime == after.mtime &&
             before.ctime == after.ctime && bytes == after.size
        raise ValidationError, "#{label} changed while hashing"
      end
      { "byte_size" => bytes, "sha256" => digest.hexdigest }
    end

    # Returns an existing non-symlink absolute expanded source directory.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def expanded_source_root(path)
      raise ValidationError, "source evidence root is required" if path.nil? || path.to_s.strip.empty?
      root = File.expand_path(path)
      raise ValidationError, "source evidence root does not exist: #{root}" unless Dir.exist?(root)
      raise ValidationError, "source evidence root may not be a symlink: #{root}" if File.symlink?(root)
      root
    end

    # Returns an existing regular non-symlink absolute path for the named input.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def existing_regular_file!(path, label)
      raise ValidationError, "#{label} path is required" if path.nil? || path.to_s.strip.empty?
      expanded = File.expand_path(path)
      raise ValidationError, "#{label} may not be a symlink: #{expanded}" if File.symlink?(expanded)
      raise ValidationError, "Missing #{label}: #{expanded}" unless File.file?(expanded)
      expanded
    end

    # Checks that mapping keys are strings belonging to the supplied allowed set.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def exact_keys!(hash, allowed, label)
      unless hash.keys.all? { |key| key.is_a?(String) }
        raise ValidationError, "#{label} keys must be strings"
      end
      unknown = hash.keys - allowed
      raise ValidationError, "#{label} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    # Checks that the supplied mapping includes every required key.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def require_keys!(hash, required, label)
      missing = required.reject { |key| hash.key?(key) }
      raise ValidationError, "#{label} is missing required fields: #{missing.join(', ')}" unless missing.empty?
    end
  end
end
