# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
gem "sqlite3", "~> 2.9"
require "sqlite3"
require "tempfile"
require "tmpdir"

# Standalone evidence mechanics. Operational authorization belongs to callers.
module AfEvidence
  MANIFEST_SCHEMA_PATH = File.expand_path("../schemas/af-evidence-manifest-v0.1.schema.json", __dir__)
end

require_relative "af_evidence/error"
require_relative "af_evidence/output_safety"
require_relative "af_evidence/evidence_manifest_builder"
require_relative "af_evidence/evidence_bundle_builder"
require_relative "af_evidence/evidence_bundle_verifier"
require_relative "af_evidence/evidence_index_builder"
require_relative "af_evidence/evidence_index_lookup"
require_relative "af_evidence/evidence_index_verifier"
require_relative "af_evidence/evidence_retriever"

require_relative "af_evidence/evidence_store"
require_relative "af_evidence/evidence_equivalence_checker"
require_relative "af_evidence/evidence_release_proof"
