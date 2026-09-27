# frozen_string_literal: true
require_relative "test_helper"

class ProviderTest < Minitest::Test
  def test_llm_endpoint_rejects_unsafe_urls
    ["http://example.test/responses", "https://user:pass@example.test/responses", "https://example.test/responses?key=secret", "https://example.test/#fragment", "not a URL"].each do |url|
      assert_raises(RobotOnRails::Error) { RobotOnRails::Config.llm_endpoint!(url) }
    end
  end

  def test_reasoning_payload_and_validation
    config = RobotOnRails::Config.new({}, load_saved: false)
    payloads = []
    provider = RobotOnRails::Providers::OpenAI.new(config, transport: ->(payload) { payloads << payload; {"status" => "completed", "output" => []} })
    provider.complete(events: [], instructions: "test", tools: [])
    refute payloads.last.key?(:reasoning)
    config.reasoning_effort = "high"
    config.max_output_tokens = 16384
    provider.complete(events: [], instructions: "test", tools: [])
    assert_equal({effort: "high"}, payloads.last[:reasoning])
    assert_equal 16384, payloads.last[:max_output_tokens]
    config.reasoning_effort = "none"
    provider.complete(events: [], instructions: "test", tools: [])
    assert_equal({effort: "none"}, payloads.last[:reasoning])
    config.reasoning_effort = "invalid"
    assert_raises(RobotOnRails::Error) { provider.complete(events: [], instructions: "test", tools: []) }
    assert_equal 3, payloads.length
    config.reasoning_effort = "default"
    config.api_timeout = 0
    assert_raises(RobotOnRails::Error) { config.validate_generation! }
  end

  def test_api_timeout_reaches_http_transport
    config = RobotOnRails::Config.new({"ROBOTONRAILS_API_TIMEOUT" => "300"}, load_saved: false)
    config.api_key = "offline-test"
    config.llm_url = "https://gateway.example.test:8443/custom/responses"
    provider = RobotOnRails::Providers::OpenAI.new(config)
    response = Object.new
    def response.code = "200"
    def response.read_body = yield('{"status":"completed","output":[]}')
    http = Object.new
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    options = nil
    destination = nil
    deadline = nil
    start = ->(*args, **kwargs, &block) { destination = args; options = kwargs; block.call(http) }
    timeout = ->(seconds, &block) { deadline = seconds; block.call }
    Timeout.stub(:timeout, timeout) do
      Net::HTTP.stub(:start, start) { provider.complete(events: [], instructions: "test", tools: []) }
    end
    assert_equal ["gateway.example.test", 8443], destination
    assert_equal 300, deadline
    assert_equal 300, options[:read_timeout]
    assert_equal 0, options[:max_retries]
  end

  def test_openai_tool_round_trip_preserves_reasoning_and_call_ids
    payloads = []
    transport = lambda do |payload|
      payloads << payload
      { "status" => "completed", "output" => [
        { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "opaque" },
        { "type" => "function_call", "call_id" => "call_1", "name" => "models", "arguments" => '{"query":"Widget"}' }
      ] }
    end
    provider = RobotOnRails::Providers::OpenAI.new(RobotOnRails::Config.new({}, load_saved: false), transport: transport)
    response = provider.complete(events: [{ "kind" => "user", "text" => "Find widgets" }], instructions: "test", tools: RobotOnRails::Tools.definitions)
    assert_equal "models", response["calls"].first["name"]
    provider.complete(events: [response, { "kind" => "tool", "id" => "call_1", "result" => { "models" => ["Widget"] } }], instructions: "test", tools: [])
    assert_equal "opaque", payloads.last[:input].first["encrypted_content"]
    assert_equal "call_1", payloads.last[:input].last[:call_id]
    assert_equal false, payloads.first[:store]
    assert_equal false, payloads.first[:parallel_tool_calls]
    assert payloads.first[:tools].all? { |tool| tool[:strict] }
  end

  def test_incomplete_response_cannot_execute_partial_tools
    provider = RobotOnRails::Providers::OpenAI.new(RobotOnRails::Config.new({}, load_saved: false), transport: ->(_) { { "status" => "incomplete", "output" => [] } })
    assert_raises(RobotOnRails::Error) { provider.complete(events: [], instructions: "test", tools: []) }
  end

  def system_one(answer, read_only = nil)
    config = RobotOnRails::Config.new({ "SYSTEM_ONE_KEY" => "secret", "SYSTEM_ONE_URL" => "https://example.test/v1/systemone", "SYSTEM_ONE_MODEL" => "jev-test" }, load_saved: false)
    @payloads = []
    RobotOnRails::Providers::SystemOne.new(config, transport: ->(payload) { @payloads << payload; { "answers" => { "risk" => answer, "read_only" => read_only || {"type" => "choice", "choice" => "insufficient_evidence", "confidence" => 0.9, "probabilities" => {"read_only_supported" => 0.1, "changes_or_external_effects" => 0.0, "insufficient_evidence" => 0.9}} } } })
  end

  def answer
    { "type" => "choice", "choice" => "amber", "confidence" => 0.9, "probabilities" => { "green" => 0.05, "amber" => 0.9, "red" => 0.05 } }
  end

  def assess(client)
    client.assess(code: "Widget.count", purpose: "count", environment: "production", request: "How many widgets?", evidence: {"status" => "observed", "calls" => [{"owner" => "PluginOverride"}]}, local_signals: {level: :amber})
  end

  def test_system_one_uses_typed_choice_and_narrow_state
    result = assess(system_one(answer))
    assert_equal :amber, result[:level]
    assert_equal "insufficient_evidence", result[:read_only]
    assert_equal 1, @payloads.length
    assert_equal [:read_only, :risk], @payloads.first[:questions].keys.sort
    assert_equal "choice", @payloads.first[:questions][:risk][:type]
    assert_equal "jev-test", @payloads.first[:model]
    assert_equal "production", @payloads.first[:state][:environment]
    assert_equal "PluginOverride", @payloads.first[:state][:runtime_evidence]["calls"].first["owner"]
    assert_equal :amber, @payloads.first[:state][:local_signals][:level]
  end

  def test_rejects_invalid_system_one_answers
    [answer.merge("choice" => "other"), answer.merge("confidence" => nil),
     answer.merge("confidence" => Float::NAN), answer.merge("probabilities" => { "amber" => 1 }),
     answer.merge("probabilities" => { "green" => 0.8, "amber" => 0.1, "red" => 0.1 }),
     answer.merge("probabilities" => { "green" => 0.9, "amber" => 0.9, "red" => 0.9 })].each do |invalid|
      assert_raises(RobotOnRails::Error) { assess(system_one(invalid)) }
    end
  end

  def test_invalid_read_only_answer_rejects_entire_response
    base = {"type" => "choice", "choice" => "read_only_supported", "confidence" => 0.95,
      "probabilities" => {"read_only_supported" => 0.95, "changes_or_external_effects" => 0.0, "insufficient_evidence" => 0.05}}
    [{}, base.merge("confidence" => Float::NAN), base.merge("choice" => "green"),
     base.merge("probabilities" => {"read_only_supported" => 1.0})].each do |invalid|
      assert_raises(RobotOnRails::Error) { assess(system_one(answer, invalid)) }
    end
  end

  def test_system_one_requires_complete_configuration_and_https
    refute RobotOnRails::Config.new({ "SYSTEM_ONE_KEY" => "key" }, load_saved: false).system_one_enabled?
    assert RobotOnRails::Config.new({ "SYSTEM_ONE_KEY" => "key" }, load_saved: false).system_one_partial?
    %w[http://example.test https://key@example.test https://example.test/#fragment https://example.test/?key=secret].each do |url|
      assert_raises(RobotOnRails::Error) { RobotOnRails::Providers::SystemOne.endpoint!(url) }
    end
  end
end
