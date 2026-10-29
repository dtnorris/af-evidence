# af-evidence

Standalone Ruby evidence storage for AdventureFinder: deterministic bundles,
manifests, verification, indexing, lookup, and exact-byte retrieval.

This repository hosts the evidence mechanics extracted from af-data-pipeline
`dfb87fa1912eeabdcac895cbf4cb7b0b474ff2f9`. The project is licensed under the
MIT License; see [LICENSE](LICENSE) and the third-party notices below.

The extracted component was reviewed and tested as the OS-EV-02 code candidate.
Paired pipeline adoption remains a separate integration step. This repository
provides a source tree; no packaged gem or versioned release is provided here.

The frozen [v0.1 storage contract](https://github.com/dtnorris/af-data-pipeline/blob/dfb87fa1912eeabdcac895cbf4cb7b0b474ff2f9/docs/EVIDENCE_STORAGE_CONTRACT_V0.1.md)
governs representation and historical compatibility. This README defines the
component entry points and responsibility boundary; it does not change that
profile, AFIO/native-run or legacy Levels interpretation.

Supply this tree's `lib` explicitly on Ruby's load path:

```ruby
require "af_evidence"
builder = AfEvidence::EvidenceBundleBuilder.new(batch_root: source, batch_id: batch_id)
bundle = builder.build!(output_path: new_bundle_path)
AfEvidence::EvidenceManifestBuilder.new(batch_root: source, batch_id: batch_id).write!(
  output_path: new_manifest_path, bundle: bundle.bundle, members: bundle.members)
AfEvidence::EvidenceBundleVerifier.new.verify!(
  manifest_path: new_manifest_path, bundle_path: new_bundle_path, source_root: source)
```

Inputs in this example are caller-supplied paths/identifiers, not defaults.
Canonical layout is `<evidence_root>/<batch_id>/manifest.json` plus the
manifest-named bundle. Source and canonical pair are retained. Builders refuse
existing output and empty evidence; exact replay requires verification, not
overwriting an old identity.

| Entry | Input and result |
| --- | --- |
| `EvidenceManifestBuilder#member_inventory`, `#build`, `#write!` | Source directory and batch ID; sorted raw-byte inventory or manifest mapping. |
| `EvidenceBundleBuilder#build!` | Source/batch ID, new output path, optional exact inventory; Result with path, bundle metadata and members. |
| `EvidenceBundleVerifier#verify!` | Manifest/bundle, optional expanded source; Result with batch identity, counts, raw bundle hash and source verification flag. |
| `EvidenceIndexBuilder#build!` | Nonempty canonical evidence root and new index output outside it; counts/path Result. |
| `EvidenceIndexVerifier#verify!` | Canonical root/index; fresh logical rebuild comparison and counts/hash Result. |
| `EvidenceIndexLookup#lookup` | Explicit index and nonempty exact filters; deterministic locator mappings. Lookup alone does not establish corpus validity. |
| `EvidenceRetriever#extract_member!`, `#extract_run!` | Canonical root, validated locator(s) and a new output; MemberResult or RunResult with exact installed byte identities. |
| `EvidenceStore#ensure_pair!`, `#rebuild_index!` | Explicit batch/source/canonical root/index; exact verified pair reuse or publication, then atomically installed independently rebuilt index, with legacy file/count receipts. |
| `EvidenceEquivalenceChecker#verify!` | Explicit batch/source/canonical root/index; expanded inventory, real bundle/source, indexed batch inventory and whole-index rebuild checks. Result contains manifest/checks; Failure retains partial checks and original error. |
| `EvidenceReleaseProof#verify!` | Explicit batch, physical source/archive/canonical roots, source digest, manifest/bundle/report file receipts, report schema and current index path; independently verified local HEAD and four kind/path/SHA-256/size records. |

All classes are under `AfEvidence`. Lookup filters and result fields retain
their predecessor names. Schema paths are
`AfEvidence::MANIFEST_SCHEMA_PATH` and
`AfEvidence::EvidenceIndexBuilder::SCHEMA_PATH`; both resolve within this tree.
`Manifest.txt` lists the extracted component files, including both schemas.

Ruby syntax requires Ruby 3.2 or newer (`Data.define`); only Ruby 4.0.6 was qualified here.
Runtime dependencies are Ruby standard libraries/RubyGems tar, sqlite3
(`~> 2.9`), and an existing zstd executable. `AF_EVIDENCE_ZSTD` can select
that executable. Missing/failed compression refuses; there is no installation
or provider fallback. Tests additionally require Minitest `~> 5.0`, Rake and
SimpleCov `~> 0.22.0` (including its HTML and JSON formatters). Install the
coverage dependency once if it is not already available:

```sh
gem install simplecov -v '~> 0.22.0' --no-document
```

Invalid evidence, unsafe destinations, stale indexes, identity conflicts and
compression failures raise `AfEvidence::ValidationError < AfEvidence::Error`.
Filesystem errors, callback errors and unavailable Ruby dependencies can also
propagate. Compression/decompression collaborators are retained for existing
tests; the production defaults invoke real zstd.

EV always checks local retrieval safety: no traversal, symlink output/ancestor,
canonical-root overlap, existing destination, or missing/unwritable parent.
Exclusive creation protects conflicting outputs; failures remove only newly
created incomplete output. Callers must still authorize the destination and
coordinate concurrent filesystem changes. These checks do not claim to defend
against a hostile actor replacing directories during a call.

The paired pipeline adapter is responsible for selected-root/opt-in
authorization and translating EV errors to existing pipeline exceptions. PL owns
production modes/labels, authoritative versus diagnostic policy, completion,
root eligibility and the durable two-phase expanded-source release state.
The four mechanical checks and storage/publication implementation live only in EV.
Optional equivalence reuse mappings are trusted in-process results from the real
writer, not externally verifiable tokens. Release proof never uses them.

`EvidenceReleaseProof#verify!` revalidates the exact pair against the bound source,
the finalized report and current independently rebuilt index. It compares all
four actual HEAD blobs, stage-zero index entries and working bytes/modes. The
report's index hash describes its original verification; release validates the
current index because the corpus can grow. Local HEAD proof establishes neither
remote retention nor publication clearance.

`EvidenceReleaseProof#release!` always repeats that proof and requires a block
which validates the caller's bound durable authorization before deletion. PL's
adapter rereads its exact persisted `release_authorized` state and compares the
fresh HEAD/four records to that authorization. A serialized receipt is never
passed to EV as permission to skip proof. The block is a trusted application
authorization boundary, not an independent evidence verifier. No callback can
substitute for EV's real checks. Callers must serialize writers; this is not a
hostile-filesystem or power-loss transaction.

EV never marks an operation accepted. No workload state, scoring acceptance,
catalog role, method binding or historical locator is reinterpreted. PL alone
interprets recovery with an already absent source under its previously trusted
state; that fast path is not fresh authorization for another source.

Run all component tests (mechanical, output safety and release proof) from this
tree with existing gems:

```sh
rake
# Equivalent explicit task; TESTOPTS supplies optional Minitest arguments:
rake test TESTOPTS='--no-plugins --seed=1402'
```

The explicit Minitest 5 activation and standard `--no-plugins` option avoid
the inspected host's mixed-version plugin discovery. The Rake task defaults to
`--no-plugins`; include it when overriding `TESTOPTS`. It discovers
`test/**/*_test.rb`, adds `lib` to the load path and fails if the tests fail.
No framework is modified. The repository has no Gemfile; run `rake` directly.

Every `rake` or `rake test` invocation captures line and branch coverage during
that same test process. `rake test:coverage` is an alias for `test`, so even
`rake test test:coverage` executes the suite once. The shared ACT entry point is
`ruby -Ilib:test test/run_tests.rb`; it also runs the suite once with coverage.

Reports are written to ignored `coverage/index.html` and
`coverage/coverage.json`. Coverage starts before production code loads, tracks
all `lib/**/*.rb` files (including unloaded files), excludes tests and does not
merge earlier runs. A failing test run still fails; report generation is not
test acceptance. This change captures coverage without adding a threshold.

## License and third-party notices

Project code is distributed under the [MIT License](LICENSE), subject to the
upstream notices for the tar path-splitting logic below. Runtime dependencies
are required separately; their implementations are not bundled in this tree.

### RubyGems tar path splitting

The `split_tar_name` helper in
`lib/af_evidence/evidence_bundle_builder.rb` follows the name/prefix splitting
logic in RubyGems' `Gem::Package::TarWriter#split_name`:

- [Upstream implementation](https://github.com/ruby/rubygems/blob/master/lib/rubygems/package/tar_writer.rb)
- [Upstream MIT license](https://github.com/ruby/rubygems/blob/master/MIT.txt)

The upstream source file carries this notice:

```text
Copyright (C) 2004 Mauricio Julio Fernández Pradier
```

The RubyGems MIT license notice is reproduced below:

```text
Copyright (c) Chad Fowler, Rich Kilmer, Jim Weirich and others.
Portions copyright (c) 2010-2019 André Arko
Portions copyright (c) 2009 Engine Yard

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

