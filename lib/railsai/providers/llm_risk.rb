# frozen_string_literal: true
module RailsAI
  module Providers
    class LLMRisk
      attr_reader :usage, :last_debug

      def initialize(config, provider: OpenAI.new(config), redactor: Redactor.new)
        @config = config
        @provider, @redactor = provider, redactor
        @usage = { "input_tokens" => 0, "output_tokens" => 0 }
      end

      def assess(code:, purpose:, environment:, request:, evidence:, local_signals:)
        state = @redactor.call({ code: code, purpose: purpose, environment: environment,
          user_request: request, runtime_evidence: evidence, local_signals: local_signals })
        payload = {
          events: [{ "kind" => "user", "text" => JSON.generate(state) }],
          instructions: "#{Risk::INSTRUCTIONS}\nCriteria: #{JSON.generate(Risk::CRITERIA)}\n#{Risk::READ_ONLY_INSTRUCTIONS} Read-only criteria: #{JSON.generate(Risk::READ_ONLY_CRITERIA)} Return both judgments and their separate confidence from 0 to 1. Do not execute anything.",
          tools: [{ name: "report_risk", description: "Report the operational risk assessment only.",
            parameters: { type: "object", properties: {
              level: { type: "string", enum: %w[green amber red] },
              confidence: { type: "number", minimum: 0, maximum: 1 },
              read_only: { type: "string", enum: Risk::READ_ONLY_CRITERIA.keys.map(&:to_s) },
              read_only_confidence: { type: "number", minimum: 0, maximum: 1 }
            }, required: %w[level confidence read_only read_only_confidence], additionalProperties: false } }],
          tool_choice: { type: "function", name: "report_risk" } }
        @last_debug = { "endpoint" => @config.llm_url, "model" => @config.model,
          "reasoning_effort" => @config.reasoning_effort, "max_output_tokens" => @config.max_output_tokens,
          "request" => payload, "response_status" => "pending" }
        response = @provider.complete(**payload)
        @last_debug["response_status"] = "received"
        response.fetch("usage", {}).each do |key, value|
          @usage[key] += value if @usage.key?(key) && value.is_a?(Integer) && value >= 0
        end
        calls = response.fetch("calls")
        raise Error, "Invalid LLM risk assessment." unless calls.is_a?(Array) && calls.length == 1 && calls.first["name"] == "report_risk"
        args = calls.first.fetch("arguments")
        raise Error, "Invalid LLM risk assessment." unless args.is_a?(Hash) && args.keys.sort == %w[confidence level read_only read_only_confidence]
        confidence = args["confidence"]
        valid = %w[green amber red].include?(args["level"]) && confidence.is_a?(Numeric) && confidence.finite? && confidence.between?(0, 1)
        valid &&= Risk::READ_ONLY_CRITERIA.key?(args["read_only"]&.to_sym) &&
          args["read_only_confidence"].is_a?(Numeric) && args["read_only_confidence"].finite? && args["read_only_confidence"].between?(0, 1)
        raise Error, "Invalid LLM risk assessment." unless valid
        @last_debug["response_status"] = "validated"
        @last_debug["response"] = { "answer" => args, "usage" => response["usage"],
          "confidence_kind" => "LLM self-reported; no probability distribution provided" }
        { level: args["level"].to_sym, confidence: confidence, read_only: args["read_only"], read_only_confidence: args["read_only_confidence"] }
      rescue KeyError, TypeError, NoMethodError
        raise Error, "Malformed LLM risk response."
      end
    end
  end
end
