# frozen_string_literal: true
require_relative "test_helper"

class RenameCompatibilityTest < Minitest::Test
  def test_old_environment_names_work_and_new_names_win
    config = RobotOnRails::Config.new({"RAILSAI_MODEL" => "legacy", "RAILSAI_SYSTEM_ONE_KEY" => "fake-legacy"}, load_saved: false)
    assert_equal "legacy", config.model
    assert_equal "fake-legacy", config.system_one_key
    config = RobotOnRails::Config.new({"RAILSAI_MODEL" => "legacy", "ROBOTONRAILS_MODEL" => "current"}, load_saved: false)
    assert_equal "current", config.model
  end

  def test_existing_configuration_is_used_without_copying_credentials
    Dir.mktmpdir do |base|
      legacy = File.join(base, "railsai")
      FileUtils.mkdir_p(legacy)
      File.write(File.join(legacy, "config.yml"), "model: legacy\n")
      env = {"XDG_CONFIG_HOME" => base}
      assert_equal legacy, RobotOnRails::SettingsStore.new(env).directory
      current = File.join(base, "robotonrails")
      FileUtils.mkdir_p(current)
      assert_equal current, RobotOnRails::SettingsStore.new(env).directory
      assert_equal legacy, RobotOnRails::SettingsStore.new(env.merge("RAILSAI_CONFIG_DIR" => legacy)).directory
      assert_equal current, RobotOnRails::SettingsStore.new(env.merge("RAILSAI_CONFIG_DIR" => legacy, "ROBOTONRAILS_CONFIG_DIR" => current)).directory
    end
  end

  def test_legacy_keyring_namespace_is_looked_up_after_new_namespace
    Dir.mktmpdir do |base|
      exe = File.join(base, "secret-tool")
      File.write(exe, "")
      File.chmod(0o700, exe)
      calls = []
      service = RobotOnRails::SecretService.new({"PATH" => base}, runner: ->(_, args, _) {
        calls << args
        args.include?("railsai") ? ['{"system_one_key":"fixture-only"}', true] : ["", false]
      })
      assert_includes service.lookup("fixture-id"), "fixture-only"
      assert_equal %w[robotonrails railsai], calls.map { |args| args[2] }
    end
  end
end
