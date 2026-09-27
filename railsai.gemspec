# frozen_string_literal: true
require_relative "lib/railsai/version"

Gem::Specification.new do |spec|
  spec.name = "railsai"
  spec.version = RailsAI::VERSION
  spec.summary = "An English-first terminal assistant for your Rails application"
  spec.description = "Conversational Rails inspection and explicitly approved Ruby execution in a separate worker."
  spec.authors = ["RailsAI contributors"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["railsai"]
  spec.require_paths = ["lib"]
  spec.add_dependency "psych", ">= 4", "< 6"
  spec.add_dependency "io-console", ">= 0.5", "< 1"
  spec.add_dependency "json", ">= 2.6", "< 3"
  spec.add_dependency "net-http", ">= 0.3", "< 1"
end
