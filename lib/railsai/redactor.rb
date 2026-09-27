# frozen_string_literal: true
module RailsAI
  class Redactor
    def initialize(env = ENV, secrets: [])
      @secrets = env.select { |key, value| key.match?(/KEY|TOKEN|PASSWORD|SECRET|CREDENTIAL/i) && value.to_s.length >= 8 }.values.concat(secrets.compact.reject(&:empty?)).uniq.sort_by { |s| -s.length }
    end

    def text(value)
      result = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      @secrets.each { |secret| result = result.gsub(secret, "[REDACTED]") }
      result.gsub(/\bsk-[A-Za-z0-9_-]{12,}\b/, "[REDACTED]")
            .gsub(/(Bearer\s+)[A-Za-z0-9._~+\/-]+/i, '\1[REDACTED]')
            .gsub(/((?:password|api_key|access_token|secret_key)\s*[=:]\s*)(["']?)[^\s,"'}]+/i, '\1[REDACTED]')
    end

    def call(value)
      case value
      when Hash then value.to_h { |k, v| [k, k.to_s.match?(/\A(?:password|api_key|access_token|secret|secret_key)\z/i) ? "[REDACTED]" : call(v)] }
      when Array then value.map { |v| call(v) }
      when String then text(value)
      else value
      end
    end
  end
end
