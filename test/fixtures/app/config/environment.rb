# frozen_string_literal: true
require "rails"
require "active_record"
require "logger"

module RailsAITestApp
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = true
    config.secret_key_base = "test-only-" * 16
    config.logger = Logger.new($stdout)
    config.active_support.deprecation = :stderr
  end
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:widgets) { |t| t.string :name; t.boolean :active, default: true }
end

require File.expand_path("../plugins/demo/plugin", __dir__)
RailsAITestApp::Application.initialize!
puts "Fixture booted"
