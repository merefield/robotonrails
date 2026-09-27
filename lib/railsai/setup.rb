# frozen_string_literal: true
module RailsAI
  class Setup
    def initialize(terminal:, env: ENV, store: SettingsStore.new(env), service: SecretService.new(env))
      @terminal, @env, @store, @service = terminal, env, store, service
    end

    def run
      raise Error, "Setup needs an interactive terminal for hidden key entry." unless @terminal.interactive?
      @terminal.say("RailsAI setup\nSettings: #{@store.path('config.yml')}\nPress Enter to keep a displayed default. Ctrl-C cancels setup.")
      config = Config.new(@env, store: @store, service: @service)
      openai_key = key("OpenAI API key", existing_key(config, :api_key))
      llm_url = ask("LLM Responses endpoint", config.llm_url) do |value|
        Config.llm_endpoint!(value)
        true
      rescue Error
        false
      end
      @terminal.say("Your API key and selected application context will be sent to this endpoint.")
      model = ask("OpenAI model", config.model) { |value| !value.empty? }
      @terminal.say("Reasoning effort: #{Config::REASONING_EFFORTS.join(', ')}. Use default for the model default; supported levels depend on the model.")
      effort = ask("Reasoning effort", config.reasoning_effort) { |value| Config::REASONING_EFFORTS.include?(value) }
      @terminal.say("The output budget includes reasoning tokens. Higher effort may need more tokens and time.")
      tokens = ask("Maximum output tokens per response", config.max_output_tokens.to_s) { |value| value.match?(/\A[0-9]+\z/) && value.to_i.positive? }.to_i
      api_timeout = ask("OpenAI timeout in seconds", config.api_timeout.to_s) { |value| value.match?(/\A[0-9]+\z/) && value.to_i.positive? }.to_i
      use_jev = yes?("Use Jev for risk assessment?", default: @store.settings.fetch("system_one_enabled", false))
      secrets = { "openai_api_key" => openai_key }
      settings = { "version" => 1, "llm_url" => llm_url, "model" => model, "system_one_enabled" => use_jev, "reasoning_effort" => effort, "max_output_tokens" => tokens, "api_timeout" => api_timeout }
      if use_jev
        secrets["system_one_key"] = key("TypeSafe API key", existing_key(config, :system_one_key))
        settings["system_one_url"] = ask("System One endpoint", config.system_one_url || "https://api.typesafe.ai/v1/systemone") do |value|
          Providers::SystemOne.endpoint!(value)
          true
        rescue Error
          false
        end
        settings["system_one_model"] = ask("System One model", config.system_one_model || "jev-latest") { |value| !value.empty? }
      end
      @terminal.say("Review policy: 0 review every action; 1 auto-run supported reads; 2 also auto-run confident green/amber Ruby.")
      settings["risk_appetite"] = ask("Risk appetite", config.risk_appetite.to_s) { |value| %w[0 1 2].include?(value) }.to_i
      default_root = config.root
      default_root = File.expand_path("~/discourse") if !File.file?(File.join(default_root, "config/environment.rb")) && File.file?(File.expand_path("~/discourse/config/environment.rb"))
      settings["root"] = File.expand_path(ask("Rails application", default_root) { |value| File.file?(File.join(File.expand_path(value), "config/environment.rb")) })
      settings["environment"] = ask("Rails environment", config.environment) { |value| value.match?(/\A[a-zA-Z0-9_-]+\z/) }
      backend = choose_backend
      return 0 unless backend
      @terminal.say("\nSave #{settings['root']} / #{settings['environment']}\nLLM URL: #{llm_url}\nModel: #{model}; risk appetite: #{settings['risk_appetite']}; Jev: #{use_jev ? 'enabled' : 'disabled'}\nReasoning: #{effort}; output token limit: #{tokens}; API timeout: #{api_timeout}s\nKey storage: #{backend == 'file' ? @store.path('credentials.json') + ' (plaintext, owner-only)' : 'OS Secret Service'}")
      unless yes?("Save this configuration?", default: true)
        @terminal.say("Cancelled. No configuration was saved.")
        return 0
      end
      if backend == "secret_service"
        begin
          id = SecureRandom.uuid
          @service.store(id, JSON.generate(secrets))
          settings["credential_id"] = id
        rescue Error => e
          @terminal.say(e.message)
          return 0 unless allow_file?
          backend = "file"
        end
      end
      Credentials.validate!(secrets)
      @store.write("credentials.json", JSON.pretty_generate(secrets) + "\n") if backend == "file"
      settings["credential_backend"] = backend
      @store.save(settings)
      @terminal.say("\nSaved #{@store.path('config.yml')}.\nRun railsai to start, or railsai doctor to check application startup. No API requests were made.")
      if backend == "secret_service" && File.exist?(@store.path("credentials.json"))
        @terminal.say("An older credentials.json remains unused; remove it if you no longer need that backup.")
      end
      @terminal.say("Existing exported environment variables override saved settings; no shell files were changed.")
      0
    rescue Interrupt
      @terminal.say("\nSetup cancelled.")
      130
    end

    private

    def existing_key(config, name)
      config.public_send(name)
    rescue Error => e
      @terminal.say(e.message)
      nil
    end

    def key(label, current)
      loop do
        suffix = current.to_s.empty? ? "" : " (Enter keeps the current key)"
        value = @terminal.secret("#{label}#{suffix}: ")
        raise Interrupt if value.nil?
        value = value.strip
        value = current if value.empty? && !current.to_s.empty?
        begin
          Credentials.validate!({ "openai_api_key" => value })
          return value
        rescue Error
          @terminal.say("Enter a non-empty API key without whitespace (maximum 4096 bytes).")
        end
      end
    end

    def ask(label, default)
      loop do
        input = @terminal.prompt("#{label} [#{default}]: ")
        raise Interrupt if input.nil?
        value = input.strip.empty? ? default.to_s : input.strip
        return value if !value.match?(/[\x00-\x1f\x7f]/) && value.bytesize <= 4096 && yield(value)
        @terminal.say("Invalid value; please try again.")
      end
    end

    def yes?(label, default: false)
      loop do
        answer = @terminal.prompt("#{label} #{default ? '[Y/n]' : '[y/N]'}: ")
        raise Interrupt if answer.nil?
        answer = answer.strip.downcase
        return default if answer.empty?
        return true if %w[y yes].include?(answer)
        return false if %w[n no].include?(answer)
        @terminal.say("Enter y or n.")
      end
    end

    def choose_backend
      return "secret_service" if @service.available? && yes?("Store keys in your OS credential store?", default: true)
      @terminal.say("OS credential storage is unavailable or was not selected.")
      allow_file? ? "file" : nil
    end

    def allow_file?
      accepted = yes?("Save API keys as plaintext in #{@store.path('credentials.json')} with owner-only permissions (0600)?")
      @terminal.say("Cancelled. No file credentials were saved.") unless accepted
      accepted
    end
  end
end
