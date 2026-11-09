# af-evidence

Standalone Ruby evidence storage for AdventureFinder: deterministic bundles,
manifests, verification, indexing, lookup, and exact-byte retrieval.

This repository hosts the evidence mechanics extracted from af-data-pipeline
`dfb87fa1912eeabdcac895cbf4cb7b0b474ff2f9`. The project is licensed under the
MIT License; see [LICENSE](LICENSE) and the third-party notices below.

OS-EV-03 accepted the paired EV implementation at
`4be62c5baa491e42c2d9b65dc72f5bf2e0647707` and pipeline adapter at
`7b3572dfde0a59763681b9dffbd42455fed53542`. That historical acceptance does
not qualify a new package or establish installed consumer state. This tree
supports a privately reviewed source archive; no registry gem, public acquisition
channel or versioned release is provided here. Packaging does not establish
rights clearance, installed migration or publication approval.

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
`Manifest.txt` is the reviewed source distribution inventory, including both
schemas, dependency files, test/coverage support, license and this README's notices.

## Private source package and first store

Obtain the complete reviewed candidate from its operator handoff, and verify its
patch/package SHA-256 before use. Public installation is not part of this
procedure. From the candidate root, one command builds an allowlisted tar and
prints its file inventory, modes, sizes and SHA-256 values:

```sh
ruby script/package.rb /ABSOLUTE/NEW/SCRATCH/af-evidence-source.tar > /ABSOLUTE/NEW/SCRATCH/inventory.json
```

The output parent must already exist and be physical (no symlink ancestors).
The tar must be new and outside the source tree. Construction refuses missing,
nonregular, symlinked, unsafe or duplicate selected files and unsafe modes.
Unselected files, Git metadata, settings, generated evidence and coverage are
excluded. Dependencies remain external. The inventory JSON is a review receipt
beside the archive, not an additional archive member. Preserve both together.

Ruby must be >= 3.2 (`Data.define`), with Bundler matching the frozen lock
(currently 4.0.17), Ruby standard libraries/RubyGems tar, csv `~> 3.3`, sqlite3
`~> 2.9`, and an existing zstd executable. Runtime uses only these dependencies.
Tests additionally use Minitest `~> 5.0`, Rake `~> 13.0`, SimpleCov `~> 0.22.0`
and its locked HTML/JSON formatters and dependencies. Keep `Gemfile.lock` unchanged;
do not substitute installed versions for its selections. An operator must
provision missing dependencies separately; none of these commands installs them.

The accepted EV history qualified Ruby 4.0.6. The OS-EV-04 worker observed
Ruby 4.0.9 / arm64-darwin27, Bundler 4.0.17 and zstd 1.5.7, but its locked
csv/sqlite3 and coverage gems were unavailable, and nested sandbox execution
was denied. Thus the new fresh-root runtime journey and coverage gates remain
unqualified pending host execution. Other runtimes/platforms are unqualified;
lockfile platform entries alone are not test results.

The following zsh walkthrough uses a new physical scratch root, the reviewed
local archive, and installed external dependencies. Replace the two artifact
paths with the handoff paths. Verify the receipt/archive digest before unpacking;
use only this trusted package (the smoke gate also checks each member).

```sh
archive=/ABSOLUTE/REVIEWED/af-evidence-source.tar
inventory=/ABSOLUTE/REVIEWED/inventory.json
scratch=$(ruby -rtmpdir -e 'puts Dir.mktmpdir("af-evidence-first-", File.realpath(Dir.tmpdir))')
mkdir "$scratch/package"
tar -xf "$archive" -C "$scratch/package"
cd "$scratch/package"
ruby -v
bundle --version
env BUNDLE_IGNORE_CONFIG=true BUNDLE_FROZEN=true bundle check
zstd --version
env -u RUBYLIB -u RUBYOPT BUNDLE_IGNORE_CONFIG=true BUNDLE_FROZEN=true \
  BUNDLE_GEMFILE="$scratch/package/Gemfile" BUNDLE_WITHOUT=development:test \
  bundle exec ruby -Ilib examples/first_store.rb "$scratch/first-store"
```

Stop on any failed command. `AF_EVIDENCE_ZSTD=/absolute/path/to/zstd` selects
an external executable for the example and smoke gate; check that selected
executable with `--version` instead of the plain `zstd` command. Missing/failed
compression refuses; no installer or alternate provider is invoked. The example
uses the real owner methods and generated metadata, binary and empty files. It
creates a previously absent scratch directory and an initially empty evidence
root, then writes the first canonical pair, verifies against source, builds and
queries the index, retrieves exact bytes, and deletes/rebuilds only its disposable
derived index. It compares logical rows and source/pair hashes/modes and prints
loaded EV features, dependency roots, schema paths/hashes and resulting identities.
The manifest JSON schema is read in example preflight; EV itself retains its
existing validation and schema resolution semantics. Empty input remains invalid.

Run the repeatable distribution smoke gate from the candidate root. Pass actual
absolute development, pipeline and private archive roots to make them unavailable
to child processes; append other EV installations/checkouts or private roots that
exist on the test host. No archive data is copied or inspected:

```sh
ruby script/package_smoke.rb "$archive" "$inventory" \
  /ABSOLUTE/CANDIDATE/af-evidence \
  /ABSOLUTE/DEVELOPMENT/af-data-pipeline \
  /ABSOLUTE/PRIVATE/ARCHIVE
```

This gate currently requires macOS `sandbox-exec` with permission to create a
child sandbox. It uses a new unpacked package without `.git`, a replaced child
environment, that package's frozen Gemfile and installed external gem paths. It
denies network and access to the declared roots, probes denial of the invoking
source, and restricts writes to its own scratch root. A denied/unavailable sandbox
is a blocked isolation gate, never a pass. It checks archive/member hashes/modes,
construction refusals, the real first-store journey, removed implementation and
both schema failures, existing mechanical refusal tests, exact restoration and a
repeat positive. Each command prints argv, cwd, exit/signal, duration and bounded
streams. Scratch results are retained at the printed path for review. Run the
gate against the final archive bytes; historical EV tests do not qualify them.

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
bundle exec rake
# Equivalent explicit task; TESTOPTS supplies optional Minitest arguments:
bundle exec rake test TESTOPTS='--no-plugins --seed=1402'
```

The explicit Minitest 5 activation and standard `--no-plugins` option avoid
the inspected host's mixed-version plugin discovery. The Rake task defaults to
`--no-plugins`; include it when overriding `TESTOPTS`. It discovers
`test/**/*_test.rb`, adds `lib` to the load path and fails if the tests fail.
No framework is modified. Use the included Gemfile and frozen lock with the
declared test dependencies. A packaging-only focused check is
`ruby test/source_package_test.rb --no-plugins --seed=1402`; it does not load EV,
require native gems or substitute for the covered component suite.

Every `rake` or `rake test` invocation captures line and branch coverage during
that same test process. `rake test:coverage` is an alias for `test`, so even
`rake test test:coverage` executes the suite once. The shared ACT entry point is
`ruby -Ilib:test test/run_tests.rb`; it also runs the suite once with coverage.

Reports are written to ignored `coverage/index.html` and
`coverage/coverage.json`. Coverage starts before production code loads, tracks
all `lib/**/*.rb` files (including unloaded files), excludes tests and does not
merge earlier runs. A failing test run still fails; report generation is not
test acceptance. The existing line and branch ratchets are mandatory; see
[COVERAGE.md](COVERAGE.md) and the included `coverage-baseline.json`.

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

