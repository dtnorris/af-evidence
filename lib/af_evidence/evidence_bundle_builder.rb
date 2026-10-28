# frozen_string_literal: true

module AfEvidence
  # Owns evidence bundle builder mechanics independently of pipeline policy.
  class EvidenceBundleBuilder
    FORMAT = "tar+zstd"
    PROFILE_VERSION = "af-evidence-bundle/tar-zstd-v0.1"
    ZSTD_LEVEL = 9
    TAR_MODE = 0o644
    SOURCE_DATE_EPOCH = "0"

    Result = Struct.new(:path, :bundle, :members, keyword_init: true)

    # External zstd process boundary; no provider or workflow execution.
    class ZstdCompressor
      # Binds the supplied paths and collaborators for later calls; returns the instance.
      # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
      def initialize(command: ENV.fetch("AF_EVIDENCE_ZSTD", "zstd"))
        @command = command
      end

      # Compresses source_path to output_path with the fixed v0.1 zstd profile; returns nil on success.
      # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
      def compress!(source_path:, output_path:)
        _stdout, stderr, status = Open3.capture3(
          @command,
          "-q",
          "-f",
          "-T1",
          "-#{ZSTD_LEVEL}",
          "--no-check",
          "-o",
          output_path,
          source_path
        )
        return if status.success?

        detail = stderr.to_s.strip
        detail = "exit #{status.exitstatus}" if detail.empty?
        raise ValidationError, "zstd compression failed: #{detail}"
      rescue Errno::ENOENT
        raise ValidationError,
              "zstd compressor not found: #{@command.inspect}; install zstd or set AF_EVIDENCE_ZSTD"
      end
    end

    attr_reader :batch_root, :batch_id

    # Binds the supplied paths and collaborators for later calls; returns the instance.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def initialize(batch_root:, batch_id:, compressor: ZstdCompressor.new)
      @manifest_builder = EvidenceManifestBuilder.new(batch_root:, batch_id:)
      @batch_root = @manifest_builder.batch_root
      @batch_id = @manifest_builder.batch_id
      @compressor = compressor
    end

    # Creates a new exclusive artifact from validated source evidence and returns its Result.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def build!(output_path:, members: nil, progress: nil, progress_every: 500)
      output = safe_output_path(output_path)
      raise ValidationError, "Evidence bundle output already exists: #{output}" if File.exist?(output)
      unless File.basename(output).end_with?(".tar.zst")
        raise ValidationError, "Evidence bundle output must end in .tar.zst"
      end

      members ||= @manifest_builder.member_inventory(progress:, progress_every:)
      members = @manifest_builder.build(bundle: placeholder_bundle, members:).fetch("members")

      FileUtils.mkdir_p(File.dirname(output))
      Tempfile.create(["af-evidence-bundle-", ".tar"]) do |tar_file|
        tar_file.binmode
        write_tar!(tar_file, members, progress:, progress_every:)
        tar_file.flush
        tar_file.fsync

        Tempfile.create([".#{File.basename(output)}.", ".tmp"], File.dirname(output)) do |compressed|
          compressed.close
          @compressor.compress!(source_path: tar_file.path, output_path: compressed.path)
          raise ValidationError, "zstd compressor produced no bundle bytes" unless File.file?(compressed.path) && File.size(compressed.path).positive?

          install_exclusive!(compressed.path, output)
        end
      end

      bundle = {
        "filename" => File.basename(output),
        "format" => FORMAT,
        "profile_version" => PROFILE_VERSION,
        "byte_size" => File.size(output),
        "sha256" => Digest::SHA256.file(output).hexdigest
      }
      Result.new(path: output, bundle:, members:)
    rescue Gem::Package::TooLongFileName => e
      raise ValidationError, "Evidence member path cannot be represented by the v0.1 tar profile: #{e.message}"
    end

    private

    # Writes the canonical sorted members and tar terminator to the supplied IO; rewinds it.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def write_tar!(io, members, progress:, progress_every:)
      progress&.call(phase: :bundle_tar, current: 0, total: members.length)
      members.each_with_index do |member, index|
        add_member!(io, member)
        current = index + 1
        if current == members.length || (progress_every.positive? && (current % progress_every).zero?)
          progress&.call(phase: :bundle_tar, current:, total: members.length)
        end
      end
      io.write("\0" * 1024)
      io.rewind
    end

    # Appends one canonical tar header and exact verified source member bytes to IO.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def add_member!(io, member)
      relative = member.fetch("path")
      source = source_path(relative)
      raise ValidationError, "Evidence member may not be a symlink: #{relative}" if File.symlink?(source)
      raise ValidationError, "Evidence member is missing or not a regular file: #{relative}" unless File.file?(source)

      before = File.stat(source)
      digest = Digest::SHA256.new
      bytes = 0
      expected_size = member.fetch("byte_size")
      name, prefix = split_tar_name(relative)
      header = Gem::Package::TarHeader.new(
        name:,
        prefix:,
        mode: TAR_MODE,
        uid: 0,
        gid: 0,
        size: expected_size,
        mtime: SOURCE_DATE_EPOCH.to_i,
        typeflag: "0",
        uname: "",
        gname: ""
      )
      io.write(header.to_s)

      File.open(source, "rb") do |file|
        while (chunk = file.read(1024 * 1024))
          if bytes + chunk.bytesize > expected_size
            raise ValidationError, "Evidence member changed after inventory: #{relative}"
          end
          bytes += chunk.bytesize
          digest.update(chunk)
          io.write(chunk)
        end
      end
      after = File.stat(source)

      unless stable_stat?(before, after) && bytes == expected_size && digest.hexdigest == member.fetch("sha256")
        raise ValidationError, "Evidence member changed after inventory: #{relative}"
      end
      io.write("\0" * ((512 - (expected_size % 512)) % 512))
    end

    # Returns the v0.1 tar name/prefix pair; raises TooLongFileName if unrepresentable.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def split_tar_name(path)
      if path.bytesize > 256
        raise Gem::Package::TooLongFileName,
              "File #{path.inspect} has a too long path (should be 256 or less)"
      end

      name = path
      prefix = ""
      if name.bytesize > 100
        parts = name.split("/", -1)
        name = parts.pop
        prefix = parts.join("/")
        while !parts.empty? && (prefix.bytesize > 155 || name.empty?)
          name = parts.pop + "/" + name
          prefix = parts.join("/")
        end

        if name.bytesize > 100 || prefix.empty?
          raise Gem::Package::TooLongFileName,
                "File #{path.inspect} has a too long name (should be 100 or less)"
        end
        if prefix.bytesize > 155
          raise Gem::Package::TooLongFileName,
                "File #{path.inspect} has a too long base path (should be 155 or less)"
        end
      end

      [name, prefix]
    end

    # Returns a contained absolute source path for a relative inventory member.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def source_path(relative)
      candidate = File.expand_path(relative.split("/").join(File::SEPARATOR), batch_root)
      root = Pathname.new(batch_root)
      target = Pathname.new(candidate)
      relation = target.relative_path_from(root).to_s
      if relation == ".." || relation.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "Evidence member escapes source batch: #{relative}"
      end
      candidate
    rescue ArgumentError
      raise ValidationError, "Evidence member escapes source batch: #{relative}"
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

    # Returns structurally valid temporary bundle metadata for inventory validation.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def placeholder_bundle
      {
        "filename" => "placeholder.tar.zst",
        "format" => FORMAT,
        "profile_version" => PROFILE_VERSION,
        "byte_size" => 1,
        "sha256" => "0" * 64
      }
    end

    # Returns an absolute output path outside the supplied source/canonical root.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def safe_output_path(path)
      raise ValidationError, "Evidence bundle output path is required" if path.nil? || path.to_s.strip.empty?

      output = File.expand_path(path)
      root = Pathname.new(batch_root)
      target = Pathname.new(output)
      relative = target.relative_path_from(root).to_s
      if relative != ".." && !relative.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "Evidence bundle output must be outside the source batch: #{output}"
      end
      output
    rescue ArgumentError
      output
    end

    # Copies source bytes exclusively to destination; removes only its incomplete new file.
    # Invalid contract inputs raise ValidationError; filesystem/dependency errors propagate.
    def install_exclusive!(source, destination)
      created = false
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(destination, flags, 0o644) do |output|
        created = true
        File.open(source, "rb") { |input| IO.copy_stream(input, output) }
        output.flush
        output.fsync
      end
    rescue Errno::EEXIST
      raise ValidationError, "Evidence bundle output already exists: #{destination}"
    rescue StandardError
      FileUtils.rm_f(destination) if created
      raise
    end
  end
end
