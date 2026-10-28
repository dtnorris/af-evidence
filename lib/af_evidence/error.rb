# frozen_string_literal: true

module AfEvidence
  # Base for evidence contract failures; supports caller-specific rescue mapping.
  class Error < StandardError; end

  # Invalid bytes, identity, representation, compressor or destination input.
  class ValidationError < Error; end
end
