# frozen_string_literal: true
require_relative "test_helper"
require "open3"

class CLITest < Minitest::Test
  def test_help_and_version_do_not_need_rails_or_api_key
    output = StringIO.new
    cli = RobotOnRails::CLI.new(terminal: RobotOnRails::Terminal.new(output: output))
    assert_equal 0, cli.run(["--help"])
    assert_includes output.string, "--risk-appetite"
    assert_includes output.string, "--verbose"
    assert_equal 0, cli.run(["--version"])
    assert_includes output.string, RobotOnRails::VERSION
  end

  def test_inventory_command_uses_real_worker_without_an_api_key
    exe = File.expand_path("../exe/robotonrails", __dir__)
    app = File.expand_path("fixtures/app", __dir__)
    stdout, stderr, status = Open3.capture3({ "OPENAI_API_KEY" => nil }, RbConfig.ruby, exe, "--app", app, "--environment", "test", "--inventory")
    assert status.success?, stderr
    inventory = JSON.parse(stdout)
    assert_equal "test", inventory["environment"]
    assert inventory["plugins"].any? { |plugin| plugin["name"] == "demo" }
  end

  def test_missing_app_is_actionable
    output = StringIO.new
    cli = RobotOnRails::CLI.new(terminal: RobotOnRails::Terminal.new(error: output))
    assert_equal 1, cli.run(["--inventory", "--app", "/nonexistent/robotonrails-test"])
    assert_includes output.string, "does not exist"
  end
end
