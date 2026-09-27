# frozen_string_literal: true
require "uri"
module RobotOnRails
  class Config
    DEFAULT_LLM_URL = "https://api.openai.com/v1/responses"
    REASONING_EFFORTS = %w[default none minimal low medium high xhigh max].freeze
    attr_accessor :root, :environment, :model, :timeout, :boot_timeout,
                  :max_rounds, :inspect_only, :audit_path, :risk_appetite,
                  :system_one_url, :system_one_model, :risk_confidence, :read_only_confidence, :reasoning_effort, :max_output_tokens, :api_timeout, :llm_url

    attr_writer :api_key, :system_one_key

    def initialize(env = ENV, store: SettingsStore.new(env), service: SecretService.new(env), load_saved: true)
      saved = load_saved ? store.settings : {}
      @credentials = Credentials.new(store, saved, service: service)
      @saved_keys_enabled = saved["system_one_enabled"] != false
      @root = env.fetch("ROBOTONRAILS_APP", saved.fetch("root", Dir.pwd))
      @environment = env.fetch("RAILS_ENV", saved.fetch("environment", "development"))
      @model = env.fetch("ROBOTONRAILS_MODEL", saved.fetch("model", "gpt-4.1"))
      @api_key = env["OPENAI_API_KEY"] if env.key?("OPENAI_API_KEY")
      @timeout = 30
      @boot_timeout = 120
      @max_rounds = 12
      @inspect_only = false
      @risk_appetite = Integer(env.fetch("ROBOTONRAILS_RISK_APPETITE", saved.fetch("risk_appetite", 1)))
      @system_one_key = env["ROBOTONRAILS_SYSTEM_ONE_KEY"] || env["SYSTEM_ONE_KEY"] if env.key?("ROBOTONRAILS_SYSTEM_ONE_KEY") || env.key?("SYSTEM_ONE_KEY")
      @system_one_url = env["ROBOTONRAILS_SYSTEM_ONE_URL"] || env["SYSTEM_ONE_URL"] || env["SYSTEM_ONE_API"] || (@saved_keys_enabled && saved["system_one_url"]) || nil
      @system_one_model = env["ROBOTONRAILS_SYSTEM_ONE_MODEL"] || env["SYSTEM_ONE_MODEL"] || (@saved_keys_enabled && saved["system_one_model"]) || nil
      @risk_confidence = 0.8
      @read_only_confidence = 0.8
      @llm_url = env.fetch("ROBOTONRAILS_LLM_URL", saved.fetch("llm_url", DEFAULT_LLM_URL))
      @reasoning_effort = env.fetch("ROBOTONRAILS_REASONING_EFFORT", saved.fetch("reasoning_effort", "default"))
      @max_output_tokens = Integer(env.fetch("ROBOTONRAILS_MAX_OUTPUT_TOKENS", saved.fetch("max_output_tokens", 4096)))
      @api_timeout = Integer(env.fetch("ROBOTONRAILS_API_TIMEOUT", saved.fetch("api_timeout", 120)))
    end

    def api_key
      return @api_key if defined?(@api_key)
      @api_key = @credentials.fetch("openai_api_key")
    end

    def system_one_key
      return @system_one_key if defined?(@system_one_key)
      @system_one_key = @saved_keys_enabled ? @credentials.fetch("system_one_key") : nil
    end

    def system_one_enabled?
      [system_one_key, system_one_url, system_one_model].all? { |value| !value.to_s.strip.empty? }
    end

    def system_one_partial?
      !system_one_enabled? && [system_one_key, system_one_url, system_one_model].any? { |value| !value.to_s.strip.empty? }
    end

    def self.llm_endpoint!(value)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? && !uri.userinfo && !uri.query && !uri.fragment
        raise Error, "LLM URL must be a full HTTPS endpoint without credentials, query or fragment."
      end
      uri
    rescue URI::InvalidURIError, TypeError
      raise Error, "Invalid LLM endpoint URL."
    end

    def validate_generation!
      self.class.llm_endpoint!(llm_url)
      raise Error, "Reasoning effort must be one of: #{REASONING_EFFORTS.join(', ')}." unless REASONING_EFFORTS.include?(reasoning_effort)
      raise Error, "Output token limit and API timeout must be positive integers." unless [max_output_tokens, api_timeout].all? { |n| n.is_a?(Integer) && n.positive? }
    end

    def generation_summary
      "LLM URL: #{llm_url}\nReasoning: #{reasoning_effort}; output token limit: #{max_output_tokens}; API timeout: #{api_timeout}s"
    end

    def validate!(api: true)
      validate_generation!
      @root = File.realpath(root)
      raise Error, "No config/environment.rb in #{root}. Use --app PATH." unless File.file?(File.join(root, "config/environment.rb"))
      raise Error, "Run robotonrails setup or set OPENAI_API_KEY before starting a conversation." if api && api_key.to_s.strip.empty?
      raise Error, "Model must not be empty." if model.to_s.strip.empty?
      raise Error, "Risk appetite must be 0, 1 or 2." unless [0, 1, 2].include?(risk_appetite)
      raise Error, "Read-only confidence must be between 0 and 1." unless read_only_confidence.finite? && read_only_confidence.between?(0, 1)
      raise Error, "Risk confidence must be between 0 and 1." unless risk_confidence.finite? && risk_confidence.between?(0, 1)
      Providers::SystemOne.endpoint!(system_one_url) if api && system_one_enabled?
      raise Error, "Invalid Rails environment." unless environment.match?(/\A[a-zA-Z0-9_-]+\z/)
      raise Error, "Timeouts and round limit must be positive." unless [timeout, boot_timeout, max_rounds].all? { |n| n.positive? }
    rescue Errno::ENOENT
      raise Error, "Application directory does not exist: #{root}"
    end
  end
end
