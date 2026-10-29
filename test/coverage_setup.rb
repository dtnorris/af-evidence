# frozen_string_literal: true

# Start before production code loads. Report every library file, including
# unloaded files, without merging hits from earlier invocations.
gem "simplecov", "~> 0.22.0"
require "simplecov"
require "simplecov_json_formatter"

SimpleCov.start do
  root File.expand_path("..", __dir__)
  coverage_dir "coverage"
  command_name "af-evidence"
  enable_coverage :branch
  track_files "lib/**/*.rb"
  add_filter "/test/"
  use_merging false
end

SimpleCov.formatters = [SimpleCov::Formatter::HTMLFormatter,
                       SimpleCov::Formatter::JSONFormatter]
