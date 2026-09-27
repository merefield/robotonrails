# frozen_string_literal: true
require_relative "test_helper"

class ConversationTest < Minitest::Test
  def setup
    @config = RobotOnRails::Config.new({}, load_saved: false)
    @terminal = FakeTerminal.new
    @worker = FakeWorker.new
  end

  def action(name = "execute_ruby", arguments = { "code" => "Widget.count", "purpose" => "Count widgets", "risk" => "green" }, id = "call_1")
    { "kind" => "assistant", "text" => "", "calls" => [{ "id" => id, "name" => name, "arguments" => arguments }], "continuation" => [] }
  end

  def conversation(*responses)
    @provider = FakeProvider.new(*responses)
    @conversation = RobotOnRails::Conversation.new(config: @config, provider: @provider, worker: @worker, terminal: @terminal, redactor: RobotOnRails::Redactor.new({}))
  end

  def test_declined_code_never_reaches_worker_or_gets_retried
    conversation(action).ask("Count widgets")
    assert_empty @worker.calls
    assert_equal 1, @provider.requests.length
    assert_equal "declined", @conversation.events.last.dig("result", "status")
  end

  def test_approved_execution_returns_result_to_provider
    @terminal.approve_result = true
    conversation(action).ask("Count widgets")
    assert_equal 1, @worker.calls.length
    assert_equal "42", @provider.requests.last[:events].last.dig("result", "result", "value")
  end

  def test_inspection_only_rejects_forged_execution_call
    @config.inspect_only = true
    @terminal.approve_result = true
    conversation(action).ask("Count widgets")
    assert_empty @worker.calls
    refute @provider.requests.first[:tools].any? { |t| t[:name] == "execute_ruby" }
  end

  def test_failed_mutation_stops_without_model_retry
    @terminal.approve_result = true
    @worker.response = { "status" => "error", "error" => "Callback failed", "outcome" => "Changes may exist" }
    conversation(action).ask("Change a widget")
    assert_equal 1, @worker.calls.length
    assert_equal 1, @provider.requests.length
  end

  def test_follow_up_keeps_conversation
    chat = conversation
    chat.ask("Find widgets")
    chat.ask("Which are active?")
    assert_equal 2, @provider.requests.last[:events].count { |e| e["kind"] == "user" }
    chat.reset
    assert_empty chat.events
  end

  def test_repeated_tools_are_bounded
    responses = 4.times.map { |i| action("models", { "query" => "Widget" }, "call_#{i}") }
    conversation(*responses).ask("Find widgets")
    assert_equal 2, @worker.calls.length
    assert_equal "error", @conversation.events.last.dig("result", "status")
  end

  def test_interrupt_completes_pending_tool_calls
    @terminal.approve_result = true
    def @worker.call(*) = raise Interrupt
    chat = conversation(action)
    assert_raises(Interrupt) { chat.ask("Count widgets") }
    assert @worker.stopped
    assert_equal "stopped", chat.events.last.dig("result", "status")
    chat.ask("What happened?")
    assert_equal "assistant", chat.events.last["kind"]
  end

  def test_system_one_removes_risk_generation_from_llm_schema
    @config.system_one_key = "key"
    @config.system_one_url = "https://example.test/v1/systemone"
    @config.system_one_model = "jev-test"
    conversation.ask("Hello")
    schema = @provider.requests.first[:tools].find { |t| t[:name] == "execute_ruby" }
    refute schema[:parameters][:properties].key?("risk")
  end

  def test_edited_code_is_executed_and_returned_to_model
    terminal = @terminal
    def terminal.review(**args)
      args[:arguments].merge("code" => "Widget.limit(5).count")
    end
    conversation(action).ask("Count widgets")
    assert_equal "Widget.limit(5).count", @worker.calls.first[1]["code"]
    assert_equal "Widget.limit(5).count", @provider.requests.last[:events].last.dig("result", "executed_code")
  end
end
