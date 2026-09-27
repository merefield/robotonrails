# frozen_string_literal: true
require "net/http"
require "uri"
require "timeout"

module RailsAI
  module Providers
    class OpenAI
      MAX_RESPONSE_BYTES = 2 * 1024 * 1024

      def initialize(config, transport: nil)
        @config = config
        @transport = transport || method(:post)
      end

      def complete(events:, instructions:, tools:, tool_choice: nil)
        @config.validate_generation!
        payload = { model: @config.model, instructions: instructions, input: encode(events),
                    store: false, include: ["reasoning.encrypted_content"], max_output_tokens: @config.max_output_tokens,
                    parallel_tool_calls: false,
                    tools: tools.map { |tool| tool.merge(type: "function", strict: true) } }
        payload[:reasoning] = { effort: @config.reasoning_effort } unless @config.reasoning_effort == "default"
        payload[:tool_choice] = tool_choice if tool_choice
        data = @transport.call(payload)
        raise Error, "OpenAI response was incomplete; no actions were executed. If the output limit was reached, increase --max-output-tokens or lower --reasoning-effort." unless data["status"] == "completed"
        output = data.fetch("output")
        raise Error, "Invalid OpenAI output." unless output.is_a?(Array)
        text = output.select { |item| item["type"] == "message" }.flat_map { |item| item.fetch("content", []) }
                     .filter_map { |part| part["text"] || part["refusal"] }.join("\n")
        calls = output.select { |item| item["type"] == "function_call" }.map do |call|
          args = JSON.parse(call.fetch("arguments"))
          { "id" => call.fetch("call_id"), "name" => call.fetch("name"), "arguments" => args }
        end
        { "kind" => "assistant", "text" => text, "calls" => calls,
          "continuation" => output, "usage" => data.fetch("usage", {}) }
      rescue JSON::ParserError, KeyError, TypeError => e
        raise Error, "Invalid OpenAI response (#{e.class}). No actions were executed."
      end

      private

      def encode(events)
        events.flat_map do |event|
          case event.fetch("kind")
          when "user" then [{ role: "user", content: event.fetch("text") }]
          when "assistant" then event.fetch("continuation")
          when "tool" then [{ type: "function_call_output", call_id: event.fetch("id"), output: JSON.generate(event.fetch("result")) }]
          else raise Error, "Unknown conversation event."
          end
        end
      end

      def post(payload)
        endpoint = Config.llm_endpoint!(@config.llm_url)
        request = Net::HTTP::Post.new(endpoint)
        request["Authorization"] = "Bearer #{@config.api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        body = +""
        status = nil
        Timeout.timeout(@config.api_timeout) do
          Net::HTTP.start(endpoint.host, endpoint.port, use_ssl: true, open_timeout: [15, @config.api_timeout].min, read_timeout: @config.api_timeout, write_timeout: [30, @config.api_timeout].min, max_retries: 0) do |http|
            http.request(request) do |response|
              status = response.code.to_i
              response.read_body do |chunk|
                raise Error, "OpenAI response exceeded 2 MiB." if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
                body << chunk
              end
            end
          end
        end
        unless status.between?(200, 299)
          message = case status
                    when 401 then "Check OPENAI_API_KEY."
                    when 429 then "Rate or quota limit reached. Try again later."
                    when 400, 404 then "Check model access, supported reasoning effort and output-token limit."
                    else "The request failed. Try again later."
                    end
          raise Error, "OpenAI HTTP #{status}. #{message}"
        end
        JSON.parse(body)
      rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        raise Error, "OpenAI connection failed (#{e.class}). No automatic retry was made."
      end
    end
  end
end
