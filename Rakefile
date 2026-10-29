# frozen_string_literal: true

require "rake/testtask"

# Run every component test with the existing Minitest 5 plugin policy.
# Rake propagates a failing test process as a nonzero exit status.
Rake::TestTask.new(:test) do |test|
  test.libs << "lib"
  test.pattern = "test/**/*_test.rb"
  test.options = "--no-plugins"
end

task default: :test
