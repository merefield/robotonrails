# frozen_string_literal: true
require "optparse"

module RobotOnRails
  class CLI
    HELP = <<~TEXT
      Type a request in English. Follow up naturally.
      /help       Show commands
      /status     Show app, environment, model and token usage
      /risk-debug [PATH] Show last redacted assessment, or save a new private JSON file
      /risk N     Set risk appetite: 0 review all, 1 supported reads, 2 also confident green/amber
      /plugins    Inspect installed plugins and source roots locally
      /models     List loaded models locally
      /reset      Clear conversation (worker variables remain)
      /restart    Restart Rails and clear conversation and variables
      /exit       Leave RobotOnRails
      Ctrl-C      Stop the turn and worker; /restart to reconnect
    TEXT

    def initialize(terminal: Terminal.new)
      @terminal = terminal
    end

    def run(argv)
      if argv.first == "setup"
        raise Error, "Usage: robotonrails setup" unless argv.length == 1
        return Setup.new(terminal: @terminal).run
      end
      doctor = argv.first == "doctor"
      argv = argv.drop(1) if doctor
      config = Config.new
      inspect = false
      parser = OptionParser.new do |options|
        options.banner = "Usage: robotonrails [options] [request...]\nAn English-first console for your Rails application.\nCommands: setup (save settings), doctor (local startup check)."
        options.on("--app PATH", "Rails application directory (default: saved app or current directory)") { |v| config.root = v }
        options.on("-e", "--environment NAME", "Rails environment (default: RAILS_ENV or development)") { |v| config.environment = v }
        options.on("-m", "--model NAME", "OpenAI model (default: ROBOTONRAILS_MODEL or gpt-4.1)") { |v| config.model = v }
        options.on("--reasoning-effort LEVEL", "Model default, none, minimal, low, medium, high, xhigh or max") { |v| config.reasoning_effort = v }
        options.on("--max-output-tokens N", Integer, "Per-response output budget, including reasoning (default: 4096)") { |v| config.max_output_tokens = v }
        options.on("--api-timeout SECONDS", Integer, "OpenAI request deadline (default: 120)") { |v| config.api_timeout = v }
        options.on("--inspect-only", "Disable arbitrary Ruby execution") { config.inspect_only = true }
        options.on("--risk-appetite N", Integer, "0 review all; 1 supported reads (default); 2 also green/amber") { |v| config.risk_appetite = v }
        options.on("--read-only-confidence N", Float, "Read-only eligibility confidence for appetite 1 (default: 0.8)") { |v| config.read_only_confidence = v }
        options.on("--risk-confidence N", Float, "Colour confidence for appetite-2 auto-run (default: 0.8)") { |v| config.risk_confidence = v }
        options.on("--verbose", "Show automatic inspection steps and their arguments") { @terminal.verbose = true }
        options.on("--inventory", "Print runtime inventory without using an API key") { inspect = true }
        options.on("--timeout SECONDS", Integer, "Worker request timeout (default: 30)") { |v| config.timeout = v }
        options.on("--boot-timeout SECONDS", Integer, "Rails startup timeout (default: 120)") { |v| config.boot_timeout = v }
        options.on("--max-rounds N", Integer, "Maximum model calls per turn (default: 12)") { |v| config.max_rounds = v }
        options.on("--audit PATH", "Append private action metadata; no code or outputs") { |v| config.audit_path = v }
        options.on("-v", "--version", "Print version") { @terminal.say(VERSION); return 0 }
        options.on("-h", "--help", "Show usage") { @terminal.say(options); return 0 }
      end
      args = parser.parse(argv)
      config.validate!(api: !inspect && !doctor)
      @terminal.status("System One is partially configured; using LLM risk assessment. Set key, URL and model to enable Jev.") if !inspect && config.system_one_partial?
      redactor = inspect ? Redactor.new : Redactor.new(secrets: [config.api_key, config.system_one_key])
      @terminal.status("Loading #{config.root} (#{config.environment})…")
      worker = WorkerClient.new(config).start
      if doctor
        @terminal.say(config.generation_summary)
        @terminal.say("Rails startup: OK
Application: #{config.root}
Environment: #{config.environment}
OpenAI key: #{config.api_key.to_s.empty? ? 'missing' : 'configured'}
System One: #{config.system_one_enabled? ? 'configured' : 'disabled or incomplete'}
No API requests were made; credential validity was not checked.")
        return config.api_key.to_s.empty? ? 1 : 0
      end
      if inspect
        @terminal.say(JSON.pretty_generate(redactor.call(worker.inventory)))
        return 0
      end
      @terminal.say(config.generation_summary) if @terminal.verbose
      audit = Audit.new(config.audit_path) if config.audit_path
      system_one = Providers::SystemOne.new(config, redactor: redactor) if config.system_one_enabled?
      llm_risk = Providers::LLMRisk.new(config, redactor: redactor) unless system_one
      explainer = Providers::RiskExplanation.new(config, redactor: redactor)
      evidence = lambda do |code|
        response = worker.call("risk_evidence", { "code" => code })
        raise Error, "Runtime evidence collection failed." unless response["status"] == "ok"
        response.fetch("result")
      end
      risk = Risk.new(system_one: system_one, environment: config.environment, confidence: config.risk_confidence, read_only_confidence: config.read_only_confidence, evidence: evidence, llm: llm_risk, redactor: redactor, explainer: explainer)
      conversation = Conversation.new(config: config, provider: Providers::OpenAI.new(config), worker: worker,
                                      terminal: @terminal, redactor: redactor, audit: audit, risk: risk)
      policy = ["review all", "automatic reads", "automatic green/amber"][config.risk_appetite]
      @terminal.say("\nRobotOnRails #{VERSION} · #{File.basename(config.root)} / #{config.environment}\n#{config.model} · #{policy}#{config.inspect_only ? ' · inspection only' : ''}\nSource and selected results go to configured AI services. Risk labels are advisory. /help · /status\n")
      @terminal.say("Appetite 2 can automatically execute Ruby with application permissions.") if config.risk_appetite == 2
      assessor = system_one ? "System One / " + config.system_one_model : "LLM structured assessment"
      @terminal.say("Risk assessor: #{assessor} with runtime evidence.") if @terminal.verbose
      unless args.empty?
        conversation.ask(args.join(" "))
        return 0
      end
      loop do
        begin
          input = @terminal.prompt
          break if input.nil? || %w[/exit /quit exit quit].include?(input.strip)
          next if input.strip.empty?
          case input.strip
          when "/help" then @terminal.say(HELP)
          when "/status" then @terminal.say(config.generation_summary); @terminal.say("Risk assessor: #{assessor}\nRead-only confidence: #{config.read_only_confidence}; colour confidence: #{config.risk_confidence}"); @terminal.say("#{config.root} / #{config.environment}\nModel: #{config.model}\nRisk appetite: #{config.risk_appetite}\nTokens: #{JSON.generate(conversation.usage)}")
            @terminal.say("System One tokens: #{JSON.generate(system_one.usage)}") if system_one
            @terminal.say("LLM risk-assessment tokens: #{JSON.generate(llm_risk.usage)}") if llm_risk
            @terminal.say("Risk-explanation tokens: #{JSON.generate(explainer.usage)}")
          when "/risk-debug" then @terminal.say(risk.debug_json)
          when /\A\/risk-debug (.+)\z/
            path = input.strip.delete_prefix("/risk-debug ").strip
            risk.export_debug(path)
            @terminal.say("Saved redacted risk assessment to #{path}. It contains application code and paths; inspect before sharing.")
          when /\A\/risk [012]\z/
            config.risk_appetite = input.strip.split.last.to_i
            @terminal.say("Risk appetite: #{config.risk_appetite}. Red actions always require confirmation.")
            @terminal.say("Appetite 2 can automatically execute Ruby with application permissions.") if config.risk_appetite == 2
          when "/plugins" then @terminal.say(JSON.pretty_generate(redactor.call(worker.inventory)))
          when "/models" then @terminal.say(JSON.pretty_generate(redactor.call(worker.call("models", { "query" => "" }))))
          when "/reset" then conversation.reset; @terminal.say("Conversation cleared. Rails variables remain.")
          when "/restart" then worker.start; conversation.reset; @terminal.say("Rails restarted; conversation and variables cleared.")
          else
            input.start_with?("/") ? @terminal.say("Unknown command. /help lists commands.") : conversation.ask(input)
          end
        rescue Interrupt
          worker.stop
          @terminal.say("\nInterrupted. Worker stopped. Changes may already have occurred. Use /restart.")
        rescue Error => e
          @terminal.say(redactor.text(e.message))
        end
      end
      0
    rescue OptionParser::ParseError, Error, SystemCallError, ArgumentError => e
      @terminal.status((redactor || Redactor.new).text(e.message))
      1
    rescue Interrupt
      @terminal.status("Interrupted. Execution outcome may be unknown.")
      130
    ensure
      worker&.stop
      audit&.close
    end
  end
end
