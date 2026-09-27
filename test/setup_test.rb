# frozen_string_literal: true
require_relative "test_helper"

class SetupTest < Minitest::Test
  class WizardTerminal < FakeTerminal
    def initialize(answers, keys = ["test-openai-key"])
      super()
      @answers, @keys = answers, keys
    end
    def interactive? = true
    def prompt(label)
      say(label)
      raise "Unexpected prompt: #{label}" if @answers.empty?
      @answers.shift
    end
    def secret(label)
      say(label)
      @keys.shift
    end
  end

  class Service
    attr_reader :stored
    def initialize(available: false, fail: false)
      @available, @fail = available, fail
    end
    def available? = @available
    def store(id, text)
      raise RailsAI::Error, "Store unavailable" if @fail
      @stored = [id, text]
    end
    def lookup(id)
      raise RailsAI::Error, "Store unavailable" unless @stored
      raise "Wrong ID" unless id == @stored.first
      @stored.last
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @store = RailsAI::SettingsStore.new({}, directory: File.join(@tmp, "settings"))
    @root = File.join(@tmp, "app")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/environment.rb"), "")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def wizard(answers, service: Service.new, keys: ["test-openai-key"])
    terminal = WizardTerminal.new(answers, keys)
    result = RailsAI::Setup.new(terminal: terminal, env: {}, store: @store, service: service).run
    [result, terminal]
  end

  def answers
    ["", "", "", "", "", "n", "", @root, "", "y", "y"]
  end

  def test_file_setup_round_trip_and_environment_precedence
    code, terminal = wizard(answers)
    assert_equal 0, code
    assert_equal 0o600, File.stat(@store.path("config.yml")).mode & 0o777
    assert_equal 0o600, File.stat(@store.path("credentials.json")).mode & 0o777
    assert_equal 0o700, File.stat(@store.directory).mode & 0o777
    refute_includes File.read(@store.path("config.yml")), "test-openai-key"
    refute_includes terminal.messages.join, "test-openai-key"
    config = RailsAI::Config.new({}, store: @store)
    assert_equal "test-openai-key", config.api_key
    assert_equal @root, config.root
    assert_equal RailsAI::Config::DEFAULT_LLM_URL, config.llm_url
    assert_equal false, config.system_one_enabled?
    override = RailsAI::Config.new({"OPENAI_API_KEY" => "", "RAILSAI_MODEL" => "override", "RAILS_ENV" => "test"}, store: @store)
    assert_equal "", override.api_key
    assert_equal "override", override.model
    assert_equal "test", override.environment
    wizard(["", "", "", "", "", "n", "", "", "", "y", "y"], keys: [""])
    assert_equal "test-openai-key", RailsAI::Config.new({}, store: @store).api_key
  end

  def test_cancel_and_declined_file_storage_write_nothing
    wizard(answers[0...-1] + ["n"])
    refute File.exist?(@store.directory)
    wizard(answers[0...-2] + ["n"])
    refute File.exist?(@store.directory)
  end

  def test_credential_store_and_failure_fallback
    service = Service.new(available: true)
    wizard(answers, service: service)
    refute File.exist?(@store.path("credentials.json"))
    assert_equal "test-openai-key", RailsAI::Config.new({}, store: @store, service: service).api_key
    wizard(answers + ["y"], service: Service.new(available: true, fail: true))
    assert_equal "file", @store.settings["credential_backend"]
    assert_equal "test-openai-key", RailsAI::Config.new({}, store: @store).api_key
  end

  def test_reasoning_settings_round_trip_and_overrides
    wizard(["https://gateway.example.test/v1/responses", "", "high", "16384", "300", "n", "", @root, "", "y", "y"])
    config = RailsAI::Config.new({}, store: @store)
    assert_equal ["high", 16384, 300], [config.reasoning_effort, config.max_output_tokens, config.api_timeout]
    assert_equal "https://gateway.example.test/v1/responses", config.llm_url
    env = {"RAILSAI_LLM_URL" => RailsAI::Config::DEFAULT_LLM_URL, "RAILSAI_REASONING_EFFORT" => "default", "RAILSAI_MAX_OUTPUT_TOKENS" => "8192", "RAILSAI_API_TIMEOUT" => "180"}
    config = RailsAI::Config.new(env, store: @store)
    assert_equal RailsAI::Config::DEFAULT_LLM_URL, config.llm_url
    assert_equal ["default", 8192, 180], [config.reasoning_effort, config.max_output_tokens, config.api_timeout]
    assert_raises(RailsAI::Error) { @store.save({"reasoning_effort" => "bogus"}) }
    assert_raises(RailsAI::Error) { @store.save({"api_timeout" => 0}) }
  end

  def test_jev_configuration
    wizard(["", "", "", "", "", "y", "", "", "0", @root, "development", "y", "y"], keys: ["test-openai-key", "test-jev-key"])
    config = RailsAI::Config.new({}, store: @store)
    assert config.system_one_enabled?
    assert_equal 0, config.risk_appetite
    assert_equal "test-jev-key", config.system_one_key
  end

  def test_insecure_credentials_and_symlinks_are_rejected
    wizard(answers)
    File.chmod(0o644, @store.path("credentials.json"))
    assert_raises(RailsAI::Error) { RailsAI::Config.new({}, store: @store).api_key }
    File.unlink(@store.path("credentials.json"))
    File.symlink(@store.path("config.yml"), @store.path("credentials.json"))
    assert_raises(RailsAI::Error) { RailsAI::Config.new({}, store: @store).api_key }
    assert_raises(RailsAI::Error) { @store.write("credentials.json", "{}") }
  end

  def test_invalid_yaml_and_schema_are_rejected
    @store.write("config.yml", "--- !ruby/object:Object {}")
    assert_raises(RailsAI::Error) { @store.settings }
    @store.write("config.yml", "openai_api_key: secret")
    assert_raises(RailsAI::Error) { @store.settings }
  end

  def test_keys_are_lazy_and_saved_secrets_are_redacted
    @store.save({"credential_backend" => "secret_service", "credential_id" => "test"})
    config = RailsAI::Config.new({}, store: @store, service: Service.new)
    assert_equal "gpt-4.1", config.model
    redactor = RailsAI::Redactor.new({}, secrets: ["custom-saved-key"])
    assert_equal "[REDACTED]", redactor.text("custom-saved-key")
  end

  def test_hidden_entry_uses_noecho
    input = StringIO.new("hidden-key\n")
    def input.tty? = true
    def input.noecho
      @hidden = true
      yield
    end
    def input.hidden? = @hidden
    output = StringIO.new
    assert_equal "hidden-key", RailsAI::Terminal.new(input: input, output: output).secret("Key: ")
    assert input.hidden?
    refute_includes output.string, "hidden-key"
  end

  def test_masked_entry_supports_paste_backspace_and_clear
    input = StringIO.new("discard\x15\e[200~test-keZ\x7fy\e[201~\r")
    def input.tty? = true
    def input.noecho = yield
    def input.raw
      @raw = true
      yield
    ensure
      @restored = true
    end
    def input.restored? = @restored
    output = StringIO.new
    def output.tty? = true
    assert_equal "test-key", RailsAI::Terminal.new(input: input, output: output).secret("Key: ")
    assert input.restored?
    assert_includes output.string, "●"
    refute_includes output.string, "test"
    refute_includes output.string, "discard"
  end

  def test_masked_entry_restores_terminal_on_interrupt
    input = StringIO.new("abc\x03")
    def input.tty? = true
    def input.noecho = yield
    def input.raw
      yield
    ensure
      @restored = true
    end
    def input.restored? = @restored
    output = StringIO.new
    def output.tty? = true
    assert_raises(Interrupt) { RailsAI::Terminal.new(input: input, output: output).secret("Key: ") }
    assert input.restored?
    refute_includes output.string, "abc"
  end

  def test_doctor_boots_rails_without_contacting_providers
    require "open3"
    @store.write("credentials.json", JSON.generate({"openai_api_key" => "invalid-offline-test"}))
    @store.save({"root" => File.expand_path("fixtures/app", __dir__), "environment" => "test", "credential_backend" => "file", "system_one_enabled" => false})
    output, status = Open3.capture2e({"RAILSAI_CONFIG_DIR" => @store.directory, "OPENAI_API_KEY" => nil, "RAILS_ENV" => nil,
      "SYSTEM_ONE_KEY" => nil, "RAILSAI_SYSTEM_ONE_KEY" => nil},
      RbConfig.ruby, File.expand_path("../exe/railsai", __dir__), "doctor", "--reasoning-effort", "high", "--max-output-tokens", "16384", "--api-timeout", "300")
    assert status.success?, output
    assert_includes output, "Reasoning: high; output token limit: 16384; API timeout: 300s"
    assert_includes output, "Rails startup: OK"
    assert_includes output, "No API requests"
    refute_includes output, "invalid-offline-test"
  end

  def test_secret_service_sends_secrets_through_stdin
    exe = File.join(@tmp, "secret-tool")
    File.write(exe, "")
    File.chmod(0o700, exe)
    calls = []
    service = RailsAI::SecretService.new({"PATH" => @tmp}, runner: ->(*args) { calls << args; ["", true] })
    service.store("id", "private-value")
    assert_equal "private-value", calls.first.last
    refute_includes calls.first[1].join(" "), "private-value"
  end
end
