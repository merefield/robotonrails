# frozen_string_literal: true
require_relative "test_helper"
require "robotonrails/console"

class ConsoleWorkflowTest < Minitest::Test
  class TTY < StringIO
    def tty? = true
  end
  class Handoff
    attr_reader :code
    def available? = true
    def queue(code)
      @code = code
      true
    end
  end

  def action(code, step, id)
    {"kind" => "assistant", "text" => "", "continuation" => [], "calls" => [
      {"id" => id, "name" => "execute_ruby", "arguments" => {"code" => code, "purpose" => step, "step" => step}}
    ]}
  end

  def workflow(input, first: nil, response: nil, environment: "development")
    config = RobotOnRails::Config.new({}, load_saved: false)
    config.environment = environment
    @worker = FakeWorker.new
    def @worker.inventory = super.merge("execution_mode" => "current Rails console process")
    @worker.response = response if response
    @provider = FakeProvider.new(first || action("User.order(id: :desc).pick(:id)", "supporting", "check"),
      action("User.find(42).destroy!", "requested_action", "delete"))
    @output, @handoff = TTY.new, Handoff.new
    terminal = RobotOnRails::Console::ReviewTerminal.new(input: TTY.new(input), output: @output, handoff: @handoff)
    terminal.handoff_allowed = -> { true }
    @chat = RobotOnRails::Conversation.new(config: config, provider: @provider, worker: @worker, terminal: terminal)
    @chat.ask("Delete the user with the highest id")
  end

  def test_confirmed_supporting_step_continues_then_hands_off_only_deletion
    workflow("y\n")
    assert_equal 1, @worker.calls.size
    assert_equal "supporting", @worker.calls.first[1]["step"]
    assert_equal 2, @provider.requests.size
    assert_equal "42", @provider.requests.last[:events].last.dig("result", "result", "value")
    assert_equal "User.find(42).destroy!", @handoff.code
    assert_equal "deferred", @chat.events.last.dig("result", "status")
    assert_includes @output.string, "Supporting step"
    assert_includes @output.string, "Requested action"
    assert_equal 1, @output.string.scan("[y] Execute").size
  end

  def test_cancelled_supporting_step_stops_without_handoff
    workflow("\n")
    assert_empty @worker.calls
    assert_nil @handoff.code
    assert_equal 1, @provider.requests.size
    assert_equal "declined", @chat.events.last.dig("result", "status")
  end

  def test_supporting_error_does_not_continue_to_mutation
    workflow("y\n", response: {"status" => "error", "error" => "failed"})
    assert_equal 1, @worker.calls.size
    assert_equal 1, @provider.requests.size
    assert_nil @handoff.code
  end

  def test_edit_is_reassessed_and_result_returns_to_assistant
    workflow("e\nUser.maximum(:id)\n.end\ny\n")
    assert_equal "User.maximum(:id)", @worker.calls.first[1]["code"]
    assert_equal "User.maximum(:id)", @provider.requests.last[:events].last.dig("result", "executed_code")
    assert_equal "User.find(42).destroy!", @handoff.code
  end

  def test_production_supporting_step_requires_explicit_confirmation
    workflow("y\nexecute production\n", environment: "production")
    assert_equal 1, @worker.calls.size
    assert_includes @output.string, "execute production"
    assert_equal "User.find(42).destroy!", @handoff.code
  end

  def test_missing_step_cannot_execute_or_handoff
    first = action("User.delete_all", "requested_action", "delete")
    first["calls"].first["arguments"].delete("step")
    workflow("y\n", first: first)
    assert_empty @worker.calls
    assert_nil @handoff.code
    assert_equal "error", @chat.events.last.dig("result", "status")
  end

  def test_step_schema_is_console_only_and_rejects_unknown_values
    console = RobotOnRails::Tools.definitions(console: true).find { |tool| tool[:name] == "execute_ruby" }
    assert_includes console[:parameters][:required], "step"
    standard = RobotOnRails::Tools.definitions.find { |tool| tool[:name] == "execute_ruby" }
    refute standard[:parameters][:properties].key?("step")
    assert_raises(RobotOnRails::Error) do
      RobotOnRails::Tools.validate!("execute_ruby", {"code" => "1", "purpose" => "test", "step" => "safe"})
    end
  end
end
