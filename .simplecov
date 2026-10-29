# frozen_string_literal: true

# SimpleCov loads this project policy before the existing coverage setup starts.
# A missing or malformed committed baseline must stop startup, not merely warn.
require "json"

begin
  baseline = JSON.parse(File.binread(File.join(__dir__, "coverage-baseline.json")))
  unless baseline.is_a?(Hash) && baseline.keys.sort == %w[branch line schema source] &&
         baseline["schema"] == "af-evidence-coverage-baseline/v1" &&
         baseline["source"].is_a?(String) && !baseline["source"].strip.empty?
    raise ArgumentError, "invalid coverage baseline schema"
  end
  %w[line branch].each do |criterion|
    counts = baseline[criterion]
    unless counts.is_a?(Hash) && counts.keys.sort == %w[covered total] &&
           counts["covered"].is_a?(Integer) && counts["total"].is_a?(Integer) &&
           counts["total"].positive? && counts["covered"].between?(0, counts["total"])
      raise ArgumentError, "invalid #{criterion} baseline counts"
    end
  end
rescue StandardError => error
  abort "Coverage ratchet: #{error.message}"
end

# Reuse this process's completed result and format it once. Compare integer
# ratios, so rounding cannot conceal a regression. Never rewrite the baseline.
SimpleCov.at_exit do
  result = SimpleCov.result
  result.format!
  current = {"line" => [result.covered_lines, result.total_lines],
             "branch" => [result.covered_branches, result.total_branches]}
  failures = current.filter_map do |criterion, (covered, total)|
    expected = baseline.fetch(criterion)
    next if total.positive? && covered * expected.fetch("total") >= expected.fetch("covered") * total

    "#{criterion} #{covered}/#{total} is below baseline #{expected.fetch('covered')}/#{expected.fetch('total')}"
  end
  unless failures.empty?
    warn "Coverage ratchet failed: #{failures.join('; ')}"
    # SimpleCov will preserve an existing test/loader failure after this hook.
    # Only introduce a new failure status when the test process otherwise passed.
    existing_error = $!
    exit 1 if existing_error.nil? || existing_error.is_a?(SystemExit) && existing_error.success?
  end
  puts "Coverage ratchet passed (line and branch)" if failures.empty?
end
