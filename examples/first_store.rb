# frozen_string_literal: true

# Mechanical first-store walkthrough, run from an unpacked distribution with
# bundle exec ruby -Ilib examples/first_store.rb NEW_ABSOLUTE_SCRATCH_ROOT.
require "af_evidence"

# Returns relative file names, modes, sizes and hashes for preservation checks.
# Only generated directories are inspected; filesystem errors propagate.
def inventory(root)
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
    .select { |name| File.file?(name) }.map do |name|
      [name.delete_prefix(root + "/"), File.stat(name).mode & 0o777,
       File.size(name), Digest::SHA256.file(name).hexdigest]
    end
end

# Reads the verifier's stable logical table projections, closing the database.
# Returns a table-to-rows mapping; SQLite errors propagate.
def logical_rows(index)
  database = SQLite3::Database.new(index, readonly: true)
  AfEvidence::EvidenceIndexVerifier::TABLE_QUERIES.transform_values { |sql| database.execute(sql) }
ensure
  database&.close
end

abort "Supply one new absolute physical scratch root" unless ARGV.length == 1 &&
  Pathname.new(ARGV.first).absolute? && File.expand_path(ARGV.first) == ARGV.first &&
  File.realpath(File.dirname(ARGV.first)) == File.dirname(ARGV.first)
world = ARGV.fetch(0)
Dir.mkdir(world, 0o700) # Exclusive: never reuse a prior store or remove caller data.
package = File.realpath(File.expand_path("..", __dir__))
abort "Package must have no .git" if File.exist?(File.join(package, ".git"))
schemas = [AfEvidence::MANIFEST_SCHEMA_PATH, AfEvidence::EvidenceIndexBuilder::SCHEMA_PATH]
schema_records = schemas.map do |name|
  abort "Schema escaped package" unless File.realpath(name).start_with?(package + "/schemas/")
  {"path" => name, "sha256" => Digest::SHA256.file(name).hexdigest}
end
JSON.parse(File.binread(AfEvidence::MANIFEST_SCHEMA_PATH))
source = File.join(world, "source")
evidence = File.join(world, "evidence")
index = File.join(world, "index.sqlite")
raw = "mechanical/runs/job/native/raw/ADV-TEST/run-one"
binary = (0..255).to_a.pack("C*") + "\x00\xff".b
members = {
  "mechanical/runs/job/metadata.json" => JSON.generate("job_id" => "job", "adventure" => "ADV-TEST",
    "dimension" => "mechanical", "status" => "complete"),
  "#{raw}/run_metadata.json" => JSON.generate("run_id" => "run-one", "adventure_id" => "ADV-TEST",
    "selected_dimension" => "mechanical"), "#{raw}/binary.bin" => binary, "#{raw}/empty.bin" => "".b
}
members.each do |relative, bytes|
  target = File.join(source, relative)
  FileUtils.mkdir_p(File.dirname(target))
  File.binwrite(target, bytes)
end
Dir.mkdir(evidence)
abort "New store is not empty" unless Dir.empty?(evidence)
before_source = inventory(source)
store = AfEvidence::EvidenceStore.new(batch_id: "prod-batch-mechanical", source_root: source,
  evidence_root: evidence, index_path: index)
pair = store.ensure_pair!
verification = AfEvidence::EvidenceBundleVerifier.new.verify!(manifest_path: pair.fetch("manifest").fetch("path"),
  bundle_path: pair.fetch("bundle").fetch("path"), source_root: source)
abort "Unexpected pair verification" unless verification.source_verified && verification.member_count == 4
before_pair = inventory(evidence)
store.rebuild_index!
rows = AfEvidence::EvidenceIndexLookup.new(index_path: index).lookup(run_id: "run-one")
abort "Unexpected lookup population" unless rows.length == 3
retriever = AfEvidence::EvidenceRetriever.new(evidence_root: evidence)
{"binary.bin" => binary, "empty.bin" => "".b}.each do |name, bytes|
  locator = rows.find { |row| row.fetch("member_path") == "#{raw}/#{name}" }
  output = File.join(world, name)
  result = retriever.extract_member!(locator: locator, output_path: output)
  abort "Retrieval differs" unless File.binread(output) == bytes && result.sha256 == Digest::SHA256.hexdigest(bytes)
end
before_rows = logical_rows(index)
File.unlink(index) # Only this example's disposable, derived index.
store.rebuild_index!
abort "Rebuilt rows differ" unless before_rows == logical_rows(index)
abort "Index verification failed" unless AfEvidence::EvidenceIndexVerifier.new.verify!(
  evidence_root: evidence, index_path: index).batch_count == 1
abort "Source/pair changed" unless before_source == inventory(source) && before_pair == inventory(evidence)
features = $LOADED_FEATURES.select { |name| name.end_with?("/af_evidence.rb") || name.include?("/af_evidence/") }
expected = File.readlines(File.join(package, "Manifest.txt"), chomp: true).select { |name| name.start_with?("lib/") }
abort "EV feature closure differs" unless features.map { |name| File.realpath(name) }.sort ==
  expected.map { |name| File.join(package, name) }.sort
puts JSON.pretty_generate("status" => "pass", "ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM,
  "package" => package, "scratch" => world, "pair" => pair, "source" => before_source,
  "canonical" => before_pair, "logical_rows" => before_rows, "schemas" => schema_records,
  "features" => features.to_h { |name| [name, Digest::SHA256.file(name).hexdigest] },
  "gems" => Gem.loaded_specs.transform_values { |spec| {"version" => spec.version.to_s, "root" => spec.full_gem_path} })
