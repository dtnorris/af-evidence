# frozen_string_literal: true

module AfEvidence
  # Local retrieval safety, independent of application authorization. Requires a
  # new destination with an existing real parent outside the canonical store.
  class OutputSafety
    # Binds an existing evidence root; filesystem failures propagate to the caller.
    def initialize(evidence_root:)
      @evidence_root = File.realpath(evidence_root)
    end

    # Returns an absolute new file/directory destination without creating it.
    # Raises ValidationError for traversal, links, overlap, conflicts or a missing
    # or unwritable parent. No caller boolean or callback can bypass these checks.
    def destination!(path)
      value = path.to_s
      if value.strip.empty? || value.include?("\0") ||
         value.split(File::SEPARATOR).any? { |part| %w[. ..].include?(part) }
        raise ValidationError, "evidence retrieval output path is empty or contains traversal"
      end
      output = File.expand_path(value)
      reject_symlinks!(output)
      parent = File.dirname(output)
      unless File.directory?(parent)
        raise ValidationError, "evidence retrieval output parent is not a directory: #{parent}"
      end
      if within?(output, @evidence_root) || within?(@evidence_root, output)
        raise ValidationError, "evidence retrieval output must be outside the canonical evidence root: #{output}"
      end
      raise ValidationError, "evidence retrieval output already exists: #{output}" if File.exist?(output)
      unless File.writable?(parent) && (File.stat(parent).mode & 0o222).positive?
        raise ValidationError, "evidence retrieval output parent is unwritable: #{parent}"
      end
      output
    end

    private

    # Returns containment for absolute normalized paths without filesystem writes.
    def within?(path, root)
      path == root || path.start_with?(root + File::SEPARATOR)
    end

    # Walks existing and missing ancestors; rejects even dangling links with
    # ValidationError and returns nil after a safe walk.
    def reject_symlinks!(path)
      current = path
      loop do
        if File.symlink?(current)
          raise ValidationError, "evidence retrieval output contains a symlink: #{current}"
        end
        break if current == File.dirname(current)

        current = File.dirname(current)
      end
      nil
    end
  end
end
