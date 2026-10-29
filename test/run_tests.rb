# frozen_string_literal: true

# Shared Rake/ACT entry point: capture coverage and load each test file once.
# Minitest consumes command-line options and retains its normal failure exit.
require_relative "coverage_setup"
gem "minitest", "~> 5.0"
ENV["MT_NO_PLUGINS"] = "1"
require "minitest/autorun"

test_files = Dir.glob(File.join(__dir__, "**", "*_test.rb")).sort
abort "No component test files found" if test_files.empty?
test_files.each { |path| require path }
