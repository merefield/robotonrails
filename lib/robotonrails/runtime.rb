# frozen_string_literal: true
module RobotOnRails
  # Shared tool dispatch for the isolated worker and the opt-in console adapter.
  class Runtime
    class Scope
      def session_binding = binding
    end

    attr_reader :discovery
    attr_reader :context

    def initialize(root, context: Scope.new.session_binding)
      @discovery = Discovery.new(root)
      self.context = context
    end

    def context=(value)
      raise Error, "Context must be a Ruby binding." unless value.is_a?(Binding)
      @context = value
    end

    def call(name, args)
      Tools.validate!(name, args)
      return MethodEvidence.new(discovery.roots).collect(args.fetch("code")) if name == "risk_evidence"
      Rails.application.executor.wrap do
        if name == "execute_ruby"
          value = context.eval(args.fetch("code"), "(robotonrails)", 1)
          { "value" => value.inspect[0, 12_000] }
        else
          discovery.call(name, args)
        end
      end
    end
  end
end
