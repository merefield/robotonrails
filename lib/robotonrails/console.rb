# frozen_string_literal: true
require_relative "../robotonrails"

module RobotOnRails
  module Console
    # No subprocess, forced timeout, global stream redirection, or worker termination.
    # puts/warn/logging remain on the console; only returned values enter tool history.
    class Adapter
      attr_reader :runtime
      def initialize(root)
        @runtime = Runtime.new(root)
      end
      def inventory
        runtime.discovery.inventory.merge("execution_mode" => "current Rails console process",
          "note" => "Console process: no worker isolation or forced timeout. Output is visible locally; tool history contains returned values. Local values are accessed only by proposed Ruby. Context persists until reset.",
          "local_variable_names" => runtime.context.local_variables.map(&:to_s))
      end
      def stop; end
      def call(name, args)
        value = runtime.call(name, args)
        response = {"status" => "ok", "result" => value}
        raise Error, "Result exceeds 48 KiB. Narrow the query or source range." if JSON.generate(response).bytesize > 48 * 1024
        response
      rescue StandardError, SyntaxError => error
        {"status" => "error", "error" => "#{error.class}: #{error.message}"[0, 4000],
          "outcome" => name == "execute_ruby" ? "Changes may have occurred; inspect before retrying." : nil}
      end
    end

    # Track the actual Pry evaluating this request, including nested sessions and
    # `cd` bindings. Always restore the previous instance, even after an exception.
    module PryEvaluation
      def evaluate_ruby(code)
        previous = Thread.current[:robotonrails_pry]
        Thread.current[:robotonrails_pry] = self
        super
      ensure
        Thread.current[:robotonrails_pry] = previous
      end
    end

    class InputHandoff
      def editor
        if (pry = Console.current_pry)
          pry.input
        elsif defined?(IRB::RelineInputMethod) && Console.irb_context&.io.is_a?(IRB::RelineInputMethod)
          Reline if defined?(Reline)
        end
      end

      def available?
        input = editor
        input && [:pre_input_hook, :pre_input_hook=, :insert_text].all? { |method| input.respond_to?(method) }
      end

      def queue(code)
        return false unless available?
        input = editor
        # Restore the caller's hook before inserting. Never inject Enter or evaluate.
        previous = input.pre_input_hook
        input.pre_input_hook = proc do
          input.pre_input_hook = previous
          previous&.call
          input.insert_text(code)
          input.redisplay if input.respond_to?(:redisplay)
        end
        true
      end
    end

    class ReviewTerminal < Terminal
      attr_accessor :handoff_allowed
      def initialize(handoff: InputHandoff.new, **options)
        super(**options)
        @handoff = handoff
      end

      def review(name:, arguments:, environment:, appetite:, risk: Risk.new, **)
        return super unless name == "execute_ruby"
        assessment = risk.assess(name, arguments)
        automatic = risk.automatic?(assessment, appetite) && environment != "production" && interactive?
        unless automatic
          explanation = risk.explain_review
          queued = interactive? && @output.tty? && handoff_allowed&.call &&
            @handoff.available? && @handoff.queue(arguments.fetch("code"))
          say("")
          say("PRODUCTION") if environment == "production"
          say(arguments.fetch("purpose"))
          unless queued
            ruby_code(arguments.fetch("code"))
          end
          traffic_light(assessment, detail: "Review in console · not executed")
          say(explanation) if explanation
          say(queued ?
            "Edit the next input; Enter executes, Ctrl-C cancels. Native edits/results stay outside rai assessment and history." :
            "Input prefill unavailable for this console or binding. Nothing executed; copy Ruby into the appropriate console context to run it.")
          raise DeferredExecution, "Ruby proposed for native console review; #{queued ? 'queued in input' : 'displayed only'}. It may be edited or cancelled. Execution and result are unknown."
        end
        super(name: name, arguments: arguments, environment: environment, appetite: appetite, risk: risk, assessment: assessment)
      end
    end

    class Session
      def initialize(config: Config.new, terminal: nil, provider: nil, risk: nil)
        raise Error, "Load this helper in a running Rails application." unless defined?(Rails) && Rails.application
        @config = config
        terminal ||= ReviewTerminal.new
        @terminal = terminal
        config.root, config.environment = Rails.root.to_s, Rails.env.to_s
        config.validate!(api: provider.nil?)
        @adapter = Adapter.new(config.root)
        terminal.handoff_allowed = -> { @adapter.runtime.context.equal?(Console.current_binding) } if terminal.respond_to?(:handoff_allowed=)
        redactor = Redactor.new(secrets: [config.api_key, config.system_one_key])
        unless risk
          jev = Providers::SystemOne.new(config, redactor: redactor) if config.system_one_enabled?
          llm = Providers::LLMRisk.new(config, redactor: redactor) unless jev
          evidence = ->(code) do
            response = @adapter.call("risk_evidence", {"code" => code})
            raise Error, "Console evidence collection failed." unless response["status"] == "ok"
            response.fetch("result")
          end
          risk = Risk.new(system_one: jev, llm: llm, environment: config.environment,
            confidence: config.risk_confidence, read_only_confidence: config.read_only_confidence,
            evidence: evidence, redactor: redactor, explainer: Providers::RiskExplanation.new(config, redactor: redactor))
        end
        @conversation = Conversation.new(config: config, provider: provider || Providers::OpenAI.new(config),
          worker: @adapter, terminal: terminal, risk: risk, redactor: redactor,
          audit: config.audit_path ? Audit.new(config.audit_path) : nil)
        @redactor = redactor
        terminal.say("RobotOnRails · #{config.environment} · in-process console\nSource and selected results go to configured AI services. Approved Ruby shares this process; no worker timeout or isolation.")
      end

      def ask(request, context: nil)
        @adapter.runtime.context = context if context
        @conversation.ask(request)
        nil # Keep IRB from inspecting internal session objects or credentials.
      rescue Interrupt
        @terminal.say("Interrupted. Console remains active; changes may have occurred. Inspect before retrying.")
        nil
      rescue Error => error
        @terminal.say(@redactor.text(error.message))
        nil
      end

      def reset
        @conversation.reset
        @adapter.runtime.context = Runtime::Scope.new.session_binding
        @terminal.say("rai history and execution binding cleared. Application changes remain.")
        nil
      end
    end

    module Helper
      def rai(request = nil, context: nil)
        RobotOnRails::Console.ask(request, context: context)
      end
    end

    class << self
      def irb_context
        IRB.conf[:MAIN_CONTEXT] if defined?(IRB) && IRB.respond_to?(:conf)
      end

      def current_pry
        Thread.current[:robotonrails_pry]
      end

      def current_binding
        current_pry ? current_pry.current_binding : irb_context&.workspace&.binding
      end

      def install_pry!
        # pry-rails may load Pry in a later Rails console hook. Load an already
        # activated optional gem now so tracking is installed before the first eval.
        require "pry" if !defined?(Pry) && Gem.loaded_specs.key?("pry")
        Pry.prepend(PryEvaluation) if defined?(Pry) && !Pry.ancestors.include?(PryEvaluation)
      end

      def install!(receiver = TOPLEVEL_BINDING.receiver, output: $stderr)
        install_pry!
        return true if receiver.singleton_class.ancestors.include?(Helper)
        if receiver.respond_to?(:rai, true)
          output.puts("RobotOnRails: existing rai method preserved. Use RobotOnRails::Console.ask instead.")
          return false
        end
        receiver.extend(Helper)
        true
      end

      def ask(request = nil, context: nil)
        if request.nil?
          puts 'Usage: rai "request", context: binding (optional); rai :reset clears history and binding.'
          return nil
        end
        if request == :reset
          @session&.reset
          return nil
        end
        raise Error, "rai expects a request string or :reset." unless request.is_a?(String)
        raise Error, "Context must be a Ruby binding." if context && !context.is_a?(Binding)
        (@session ||= Session.new).ask(request, context: context || current_binding)
      end
    end

    if defined?(Rails::Railtie)
      class Railtie < Rails::Railtie
        console { RobotOnRails::Console.install! }
      end
    end
  end
end

RobotOnRails::Console.install! if defined?(Rails::Console)
