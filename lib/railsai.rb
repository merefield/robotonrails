# frozen_string_literal: true
require "json"
require_relative "railsai/version"

module RailsAI
  class Error < StandardError; end
  class WorkerError < Error; end
  class LimitError < Error; end
end

require_relative "railsai/settings_store"
require_relative "railsai/credentials"
require_relative "railsai/config"
require_relative "railsai/redactor"
require_relative "railsai/tools"
require_relative "railsai/risk"
require_relative "railsai/source_index"
require_relative "railsai/discovery"
require_relative "railsai/method_evidence"
require_relative "railsai/worker_client"
require_relative "railsai/providers/openai"
require_relative "railsai/providers/system_one"
require_relative "railsai/providers/llm_risk"
require_relative "railsai/providers/risk_explanation"
require_relative "railsai/conversation"
require_relative "railsai/terminal"
require_relative "railsai/setup"
require_relative "railsai/cli"
