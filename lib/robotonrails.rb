# frozen_string_literal: true
require "json"
require_relative "robotonrails/version"

module RobotOnRails
  class Error < StandardError; end
  class WorkerError < Error; end
  class LimitError < Error; end
  class DeferredExecution < Error; end
end

require_relative "robotonrails/settings_store"
require_relative "robotonrails/credentials"
require_relative "robotonrails/config"
require_relative "robotonrails/redactor"
require_relative "robotonrails/tools"
require_relative "robotonrails/risk"
require_relative "robotonrails/source_index"
require_relative "robotonrails/discovery"
require_relative "robotonrails/method_evidence"
require_relative "robotonrails/runtime"
require_relative "robotonrails/worker_client"
require_relative "robotonrails/providers/openai"
require_relative "robotonrails/providers/system_one"
require_relative "robotonrails/providers/llm_risk"
require_relative "robotonrails/providers/risk_explanation"
require_relative "robotonrails/conversation"
require_relative "robotonrails/terminal"
require_relative "robotonrails/setup"
require_relative "robotonrails/cli"
