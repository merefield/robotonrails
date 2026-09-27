# frozen_string_literal: true
require "net/http"
require "uri"
require "timeout"

module RobotOnRails
  module Providers
    class SystemOne
      LABELS = %w[green amber red].freeze
      attr_reader :usage, :last_debug

      def self.endpoint!(url)
        uri = URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment && !uri.query
          raise Error, "System One URL must be an HTTPS endpoint without credentials, query or fragment."
        end
        uri
      rescue URI::InvalidURIError
        raise Error, "Invalid System One URL."
      end

      def initialize(config, transport: nil, redactor: Redactor.new)
        @config, @redactor = config, redactor
        @endpoint = self.class.endpoint!(config.system_one_url)
        @transport = transport || method(:post)
        @usage = { "input_tokens" => 0, "output_tokens" => 0 }
      end

      def assess(code:, purpose:, environment:, request:, evidence: {}, local_signals: {})
        state = @redactor.call({ code: code, purpose: purpose, environment: environment, user_request: request, runtime_evidence: evidence, local_signals: local_signals })
        payload = { model: @config.system_one_model, state: state, questions: {
          risk: { type: "choice",
            instructions: Risk::INSTRUCTIONS,
            criteria: Risk::CRITERIA },
          read_only: { type: "choice", instructions: Risk::READ_ONLY_INSTRUCTIONS, criteria: Risk::READ_ONLY_CRITERIA }
        } }
        @last_debug = { "endpoint" => @endpoint.to_s, "request" => payload, "response_status" => "pending" }
        data = @transport.call(payload)
        @last_debug["response_status"] = "received"
        answer = data.fetch("answers").fetch("risk")
        validate_answer!(answer, LABELS)
        read_only = data.fetch("answers").fetch("read_only")
        validate_answer!(read_only, Risk::READ_ONLY_CRITERIA.keys.map(&:to_s))
        @last_debug["response_status"] = "validated"
        @last_debug["response"] = @redactor.call({ "model" => data["model"], "answer" => answer, "read_only_answer" => read_only, "usage" => data["usage"] })
        data.fetch("usage", {}).each { |key, value| @usage[key] += value if @usage.key?(key) && value.is_a?(Integer) && value >= 0 }
        { level: answer["choice"].to_sym, confidence: answer["confidence"], probabilities: answer["probabilities"],
          read_only: read_only["choice"], read_only_confidence: read_only["confidence"], read_only_probabilities: read_only["probabilities"] }
      rescue KeyError, TypeError, NoMethodError, JSON::ParserError
        raise Error, "Malformed System One risk response."
      end

      private

      def validate_answer!(answer, labels)
        probabilities = answer.fetch("probabilities")
        valid_number = ->(n) { n.is_a?(Numeric) && n.finite? && n.between?(0, 1) }
        valid = answer["type"] == "choice" && labels.include?(answer["choice"]) && valid_number.call(answer["confidence"]) &&
          probabilities.is_a?(Hash) && probabilities.keys.sort == labels.sort && probabilities.values.all?(&valid_number) &&
          (probabilities.values.sum - 1).abs <= 0.015 && probabilities[answer["choice"]] >= probabilities.values.max
        raise Error, "Invalid System One risk distribution." unless valid
      end

      def post(payload)
        request = Net::HTTP::Post.new(@endpoint)
        request["Authorization"] = "Bearer #{@config.system_one_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        body, status = +"", nil
        Timeout.timeout(10) do
          Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: true, open_timeout: 3, read_timeout: 7, write_timeout: 5, max_retries: 0) do |http|
            http.request(request) do |response|
              status = response.code.to_i
              response.read_body do |chunk|
                raise Error, "System One response exceeded 64 KiB." if body.bytesize + chunk.bytesize > 65_536
                body << chunk
              end
            end
          end
        end
        # Never follow redirects or reflect a service error body containing credentials.
        raise Error, "System One HTTP #{status}." unless status.between?(200, 299)
        JSON.parse(body)
      rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        raise Error, "System One unavailable (#{e.class})."
      end
    end
  end
end
