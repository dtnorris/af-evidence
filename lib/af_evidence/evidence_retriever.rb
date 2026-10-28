# frozen_string_literal: true

module AfEvidence
  # Owns evidence retriever mechanics independently of pipeline policy.
  class EvidenceRetriever
    MemberResult = Struct.new(
      :batch_id,
      :run_id,
      :member_path,
      :output_path,
      :byte_size,
      :sha256,
      keyword_init: true
    )
    RunResult = Struct.new(
      :batch_id,
      :run_id,
      :output_dir,
      :members,
      keyword_init: true
    )

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(evidence_root:, decompressor: EvidenceBundleVerifier::ZstdDecompressor.new)
      @evidence_root = expanded_evidence_root(evidence_root)
      @evidence_root_real = File.realpath(@evidence_root)
      @output_safety = OutputSafety.new(evidence_root: @evidence_root_real)
      @decompressor = decompressor
    end

    # Retrieves one validated locator into a new output file and returns MemberResult.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def extract_member!(locator:, output_path:)
      locator = validate_locator(locator)
      output = safe_file_output(output_path)
      created = false
      extracted = extract_locators!([locator]) do |relative, tempfile|
        install_file!(tempfile, output)
        created = true
        [relative, output]
      end
      item = extracted.fetch(0)
      MemberResult.new(
        batch_id: locator.fetch("batch_id"),
        run_id: locator["run_id"],
        member_path: locator.fetch("member_path"),
        output_path: item.fetch(:output_path),
        byte_size: locator.fetch("byte_size"),
        sha256: locator.fetch("member_sha256")
      )
    rescue StandardError
      FileUtils.rm_f(output) if created
      raise
    end

    # Retrieves one unambiguous run into a new directory and returns RunResult.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def extract_run!(locators:, output_dir:)
      locators = validate_run_locators(locators)
      output = safe_directory_output(output_dir)
      created = false
      Dir.mkdir(output)
      created = true

      extracted = extract_locators!(locators) do |relative, tempfile|
        destination = destination_under(output, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        install_file!(tempfile, destination)
        [relative, destination]
      end

      RunResult.new(
        batch_id: locators.first.fetch("batch_id"),
        run_id: locators.first.fetch("run_id"),
        output_dir: output,
        members: extracted.map do |item|
          locator = item.fetch(:locator)
          MemberResult.new(
            batch_id: locator.fetch("batch_id"),
            run_id: locator.fetch("run_id"),
            member_path: locator.fetch("member_path"),
            output_path: item.fetch(:output_path),
            byte_size: locator.fetch("byte_size"),
            sha256: locator.fetch("member_sha256")
          )
        end
      )
    rescue StandardError
      FileUtils.rm_rf(output) if created
      raise
    end

    private

    # Verifies bundle/member bytes, yielding temporary files and returning ordered output records.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def extract_locators!(locators)
      bundle = common_bundle(locators)
      bundle_path = resolve_bundle(bundle.fetch(:bundle_path))
      verify_bundle_hash!(bundle_path, bundle.fetch(:bundle_sha256))
      wanted = locators.to_h { |locator| [locator.fetch("member_path"), locator] }
      found = {}

      Tempfile.create(["af-evidence-retrieve-", ".tar"]) do |tar_file|
        tar_file.close
        @decompressor.decompress!(bundle_path:, output_path: tar_file.path)
        unless File.file?(tar_file.path) && File.size(tar_file.path).positive?
          raise ValidationError, "zstd decompressor produced no tar bytes"
        end

        File.open(tar_file.path, "rb") do |io|
          Gem::Package::TarReader.new(io) do |tar|
            tar.each do |entry|
              path = entry.full_name
              locator = wanted[path]
              next unless locator

              raise ValidationError, "duplicate requested bundle member #{path.inspect}" if found.key?(path)
              raise ValidationError, "requested bundle member is not a regular file: #{path.inspect}" unless entry.file?

              Tempfile.create(["af-evidence-member-", File.extname(path)]) do |member_file|
                member_file.binmode
                digest = Digest::SHA256.new
                bytes = 0
                while (chunk = entry.read(1024 * 1024)) && !chunk.empty?
                  bytes += chunk.bytesize
                  digest.update(chunk)
                  member_file.write(chunk)
                end
                member_file.flush
                member_file.fsync
                verify_member!(locator, bytes, digest.hexdigest)
                relative, output_path = yield(path, member_file.path)
                verify_output_file!(locator, output_path)
                found[path] = { locator:, relative:, output_path: }
              end
            end
          end
        end
      end

      missing = wanted.keys - found.keys
      unless missing.empty?
        raise ValidationError, "requested evidence members missing from bundle: #{missing.sort.join(', ')}"
      end
      locators.map { |locator| found.fetch(locator.fetch("member_path")) }
    rescue Gem::Package::TarInvalidError, EOFError => e
      raise ValidationError, "Invalid evidence tar stream during retrieval: #{e.message}"
    end

    # Returns the unique batch/bundle/hash identity shared by selected locators.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def common_bundle(locators)
      identities = locators.map do |locator|
        [locator.fetch("batch_id"), locator.fetch("bundle_path"), locator.fetch("bundle_sha256")]
      end.uniq
      unless identities.length == 1
        raise ValidationError, "selected evidence spans multiple bundles; refine the lookup"
      end
      batch_id, bundle_path, bundle_sha256 = identities.fetch(0)
      { batch_id:, bundle_path:, bundle_sha256: }
    end

    # Returns sorted unique locators for exactly one batch and nonblank native run.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_run_locators(value)
      unless value.is_a?(Array) && !value.empty?
        raise ValidationError, "run retrieval requires one or more lookup rows"
      end
      normalized = value.map { |locator| validate_locator(locator) }
      run_ids = normalized.map { |locator| locator["run_id"] }.uniq
      unless run_ids.length == 1 && run_ids.first.is_a?(String) && !run_ids.first.strip.empty?
        raise ValidationError, "run retrieval requires rows for exactly one nonblank run_id"
      end
      batches = normalized.map { |locator| locator.fetch("batch_id") }.uniq
      unless batches.length == 1
        raise ValidationError, "run retrieval spans multiple batches; refine the lookup with batch_id"
      end
      paths = normalized.map { |locator| locator.fetch("member_path") }
      raise ValidationError, "run retrieval contains duplicate member paths" unless paths.uniq.length == paths.length
      normalized.sort_by { |locator| locator.fetch("member_path") }
    end

    # Returns a locator mapping with required contained paths, hashes and sizes validated.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def validate_locator(value)
      raise ValidationError, "evidence locator must be a mapping" unless value.is_a?(Hash)
      required = %w[batch_id bundle_path bundle_sha256 member_path byte_size member_sha256]
      missing = required.reject { |key| value.key?(key) }
      raise ValidationError, "evidence locator is missing required fields: #{missing.join(', ')}" unless missing.empty?

      batch_id = nonblank_string(value.fetch("batch_id"), "locator.batch_id")
      unless /\A[a-z0-9][a-z0-9._-]*\z/.match?(batch_id)
        raise ValidationError, "locator.batch_id is invalid"
      end
      bundle_path = relative_posix_path(value.fetch("bundle_path"), "locator.bundle_path")
      member_path = relative_posix_path(value.fetch("member_path"), "locator.member_path")
      bundle_sha256 = sha256(value.fetch("bundle_sha256"), "locator.bundle_sha256")
      member_sha256 = sha256(value.fetch("member_sha256"), "locator.member_sha256")
      byte_size = value.fetch("byte_size")
      unless byte_size.is_a?(Integer) && byte_size >= 0
        raise ValidationError, "locator.byte_size must be a non-negative integer"
      end
      bundle_parts = bundle_path.split("/")
      unless bundle_parts.length == 2 && bundle_parts.first == batch_id
        raise ValidationError, "locator.bundle_path must be <batch_id>/<bundle_filename>"
      end

      value.merge(
        "batch_id" => batch_id,
        "bundle_path" => bundle_path,
        "bundle_sha256" => bundle_sha256,
        "member_path" => member_path,
        "member_sha256" => member_sha256,
        "byte_size" => byte_size
      )
    end

    # Checks a stable bundle hash against the supplied locator hash.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_bundle_hash!(path, expected_sha256)
      before = File.stat(path)
      digest = Digest::SHA256.file(path).hexdigest
      after = File.stat(path)
      unless stable_stat?(before, after)
        raise ValidationError, "evidence bundle changed while retrieving: #{path}"
      end
      unless digest == expected_sha256
        raise ValidationError,
              "evidence bundle sha256 mismatch during retrieval: index=#{expected_sha256} actual=#{digest}"
      end
    end

    # Checks retrieved byte count and hash against the supplied locator.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_member!(locator, bytes, digest)
      unless bytes == locator.fetch("byte_size")
        raise ValidationError,
              "evidence member byte size mismatch for #{locator.fetch('member_path').inspect}: index=#{locator.fetch('byte_size')} actual=#{bytes}"
      end
      unless digest == locator.fetch("member_sha256")
        raise ValidationError,
              "evidence member sha256 mismatch for #{locator.fetch('member_path').inspect}: index=#{locator.fetch('member_sha256')} actual=#{digest}"
      end
    end

    # Checks stable installed output bytes against the supplied locator.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def verify_output_file!(locator, path)
      before = File.stat(path)
      digest = Digest::SHA256.file(path).hexdigest
      after = File.stat(path)
      unless stable_stat?(before, after)
        raise ValidationError, "retrieved evidence changed while verifying output: #{path}"
      end
      verify_member!(locator, after.size, digest)
    end

    # Returns an existing contained regular bundle path for a relative locator.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def resolve_bundle(relative)
      path = File.expand_path(relative.split("/").join(File::SEPARATOR), @evidence_root)
      ensure_under_root!(path, @evidence_root, "evidence bundle")
      raise ValidationError, "evidence bundle may not be a symlink: #{path}" if File.symlink?(path)
      raise ValidationError, "Missing evidence bundle: #{path}" unless File.file?(path)
      resolved = File.realpath(path)
      ensure_under_root!(resolved, @evidence_root_real, "evidence bundle")
      path
    rescue Errno::ENOENT
      raise ValidationError, "Missing evidence bundle: #{path}"
    end

    # Returns a new absolute output after independent EV destination-safety validation.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_file_output(path)
      @output_safety.destination!(path)
    end

    # Returns a new run destination using the same output-safety checks as a file.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_directory_output(path)
      safe_file_output(path)
    end

    # Returns a contained absolute run output member path.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def destination_under(root, relative)
      destination = File.expand_path(relative.split("/").join(File::SEPARATOR), root)
      ensure_under_root!(destination, root, "retrieval destination")
      destination
    end

    # Exclusively copies a verified temporary member, cleaning only an incomplete new output.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def install_file!(source, destination)
      FileUtils.mkdir_p(File.dirname(destination))
      created = false
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(destination, flags, 0o644) do |output|
        created = true
        File.open(source, "rb") { |input| IO.copy_stream(input, output) }
        output.flush
        output.fsync
      end
    rescue Errno::EEXIST
      raise ValidationError, "evidence retrieval output already exists: #{destination}"
    rescue StandardError
      FileUtils.rm_f(destination) if created
      raise
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

    # Returns the supplied absolute path if contained beneath the named root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def ensure_under_root!(path, root, label)
      root_path = Pathname.new(root)
      target = Pathname.new(path)
      relation = target.relative_path_from(root_path).to_s
      if relation == ".." || relation.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "#{label} escapes root #{root}"
      end
      path
    rescue ArgumentError
      raise ValidationError, "#{label} escapes root #{root}"
    end

    # Returns or validates the source-relative POSIX member path for this owner.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def relative_posix_path(value, label)
      value = nonblank_string(value, label)
      if value.start_with?("/") || value.end_with?("/") || value.include?("\\") || value.include?("\0") ||
         value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
        raise ValidationError, "#{label} must be a relative POSIX path"
      end
      value
    end

    # Returns the supplied named value if it is a nonblank String.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def nonblank_string(value, label)
      unless value.is_a?(String) && !value.strip.empty?
        raise ValidationError, "#{label} must be a nonblank string"
      end
      value
    end

    # Returns the supplied value if it is a lowercase 64-character SHA256 string.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def sha256(value, label)
      unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
        raise ValidationError, "#{label} must be 64 lowercase hexadecimal characters"
      end
      value
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
  end
end
