# Coverage ratchet

Run `bundle exec rake` (or `bundle exec rake test`). The same single test
process captures coverage, writes `coverage/index.html` and
`coverage/coverage.json`, and checks the committed `coverage-baseline.json`.
`bundle exec rake test test:coverage` also executes the suite only once.

The project `.simplecov` policy is loaded by SimpleCov before the existing
coverage setup. It compares line and branch coverage independently using exact
covered/total ratios. A decrease in either ratio fails, even when the displayed
percentage rounds to the same value. A missing, malformed or invalid baseline,
or a coverage criterion with no executable denominator, also fails.

The initial baseline records the operator's passing native run: 1,234/1,526
lines and 319/607 branches. The criterion is percentage coverage, so executable
line and branch totals may change as code evolves; it is not a fixed uncovered
line count. Existing coverage scope and report generation remain unchanged.

Normal runs never update the baseline, and no second coverage run is launched.
When intentionally raising it, take covered/total counts from a passing current
report, update the source description, and review the baseline change with the
code. Neither ratio should be lowered. Keep the baseline in Git; generated
reports under `coverage/` are ignored and are not the ratchet's source of truth.
Qualify baseline increases on the intended runtime: Ruby versions can produce
different executable-line layouts for identical source.

The ratchet supplements test results. A failing test/loader process still fails
even if its captured coverage meets the baseline; coverage cannot grant test
acceptance.
