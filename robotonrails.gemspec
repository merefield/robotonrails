# frozen_string_literal: true
require_relative "lib/robotonrails/version"

Gem::Specification.new do |spec|
  spec.name = "robotonrails"
  spec.version = RobotOnRails::VERSION
  spec.summary = "An English-first terminal assistant for your Rails application"
  spec.description = "Conversational Rails inspection and explicitly approved Ruby execution in a separate worker."
  spec.authors = ["merefield"]
  spec.homepage = "https://github.com/merefield/robotonrails"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "COPYRIGHT.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["robotonrails"]
  spec.require_paths = ["lib"]
  spec.add_dependency "psych", ">= 4", "< 6"
  spec.add_dependency "io-console", ">= 0.5", "< 1"
  spec.add_dependency "json", ">= 2.6", "< 3"
  spec.add_dependency "net-http", ">= 0.3", "< 1"
end
