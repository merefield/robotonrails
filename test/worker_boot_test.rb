# frozen_string_literal: true
require_relative "test_helper"

class WorkerBootTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "config"))
    @config = RobotOnRails::Config.new({}, load_saved: false)
    @config.root = @root
    @config.boot_timeout = 10
  end

  def teardown
    @worker&.stop
    FileUtils.remove_entry(@root)
  end

  def test_load_error_is_reported_as_boot_error
    File.write(File.join(@root, "config/environment.rb"), 'raise LoadError, "missing host dependency"')
    @worker = RobotOnRails::WorkerClient.new(@config)
    error = assert_raises(RobotOnRails::WorkerError) { @worker.start }
    assert_includes error.message, "Rails boot failed: LoadError: missing host dependency"
  end

  def test_output_after_protocol_closes_is_captured
    script = File.join(@root, "crash.rb")
    File.write(script, 'IO.new(3).close; sleep 0.03; STDERR.puts "late startup diagnostic"; exit 1')
    @worker = RobotOnRails::WorkerClient.new(@config, script: script)
    error = assert_raises(RobotOnRails::WorkerError) { @worker.start }
    assert_includes error.message, "late startup diagnostic"
  end

  def test_host_bundle_activates_before_robotonrails_dependencies
    require "open3"
    File.write(File.join(@root, "Gemfile"), "source 'https://rubygems.org'\nraise 'RobotOnRails loaded before Bundler' if defined?(RobotOnRails)\n")
    File.write(File.join(@root, "config/environment.rb"), "require 'bundler/setup'\nraise 'host bundle ready'\n")
    code = <<~CODE
      c = RobotOnRails::Config.new({}, load_saved: false)
      c.root = ARGV.fetch(0)
      w = RobotOnRails::WorkerClient.new(c)
      begin
        w.start
      rescue RobotOnRails::WorkerError => e
        puts e.message
      ensure
        w.stop
      end
    CODE
    output, status = Open3.capture2e({"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil},
      RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rrobotonrails", "-e", code, @root)
    assert status.success?, output
    assert_includes output, "host bundle ready"
    refute_includes output, "RobotOnRails loaded before Bundler"
  end
end
