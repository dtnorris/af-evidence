# frozen_string_literal: true

require "rake/testtask"

# Run the shared covered suite once; Rake propagates a failing child status.
Rake::TestTask.new(:test) do |test|
  test.libs << "lib"
  test.description = "Run all component tests once with line and branch coverage"
  test.ruby_opts << "-r./test/coverage_setup"
  test.test_files = ["test/run_tests.rb"]
  test.options = "--no-plugins"
end

desc "Alias for the same single covered test run"
task "test:coverage" => :test

task default: :test
