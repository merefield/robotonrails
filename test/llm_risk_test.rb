# frozen_string_literal: true
require_relative "test_helper"

class LLMRiskTest < Minitest::Test
  def setup
    @config = RobotOnRails::Config.new({}, load_saved: false)
    @evidence = { "status" => "observed", "calls" => [{ "owner" => "PluginOverride", "source_excerpt" => "saved-secret-key" }] }
    @state = {code: "Widget.count", purpose: "count", request: "count widgets", environment: "development",
      evidence: @evidence, local_signals: {level: :amber}}
  end

  def reply(args = {"level" => "green", "confidence" => 0.95, "read_only" => "read_only_supported", "read_only_confidence" => 0.95})
    {"kind" => "assistant", "calls" => [{"name" => "report_risk", "arguments" => args}], "usage" => {"input_tokens" => 12, "output_tokens" => 3}}
  end

  def test_same_evidence_is_redacted_and_forced_into_assessment_only_schema
    provider = FakeProvider.new(reply)
    assessor = RobotOnRails::Providers::LLMRisk.new(@config, provider: provider, redactor: RobotOnRails::Redactor.new({}, secrets: ["saved-secret-key"]))
    assert_equal "read_only_supported", assessor.assess(**@state)[:read_only]
    request = provider.requests.first
    state = JSON.parse(request[:events].first["text"])
    assert_equal "PluginOverride", state["runtime_evidence"]["calls"].first["owner"]
    assert_equal "[REDACTED]", state["runtime_evidence"]["calls"].first["source_excerpt"]
    assert_equal ["report_risk"], request[:tools].map { |t| t[:name] }
    assert_equal({type: "function", name: "report_risk"}, request[:tool_choice])
    assert_includes request[:instructions], RobotOnRails::Risk::INSTRUCTIONS
    assert_equal 12, assessor.usage["input_tokens"]
  end

  def test_malformed_refused_and_invalid_assessments_require_review
    invalid = [reply({"level" => "green", "confidence" => 2}), reply({"level" => "other", "confidence" => 0.9}),
      reply({"level" => "green"}), {"calls" => []}, reply.merge("calls" => [{"name" => "execute_ruby", "arguments" => {}}])]
    invalid.each do |response|
      assessor = RobotOnRails::Providers::LLMRisk.new(@config, provider: FakeProvider.new(response))
      risk = RobotOnRails::Risk.new(llm: assessor, evidence: ->(_) { @evidence })
      result = risk.assess("execute_ruby", {"code" => "Widget.count", "purpose" => "count"})
      assert result.force_review
      refute risk.automatic?(result, 2)
    end
  end

  def test_llm_green_is_authoritative_and_edited_code_gets_new_evidence
    provider = FakeProvider.new(reply, reply)
    assessor = RobotOnRails::Providers::LLMRisk.new(@config, provider: provider)
    codes = []
    risk = RobotOnRails::Risk.new(llm: assessor, evidence: ->(code) { codes << code; @evidence })
    result = risk.assess("execute_ruby", {"code" => "Widget.count", "purpose" => "count", "risk" => "red"})
    assert_equal :green, result.level
    assert risk.automatic?(result, 1)
    assert_includes result.reason, "LLM:"
    risk.assess("execute_ruby", {"code" => "Widget.first", "purpose" => "inspect"})
    assert_equal ["Widget.count", "Widget.first"], codes
    assert_equal "Widget.first", JSON.parse(provider.requests.last[:events].first["text"])["code"]
  end

  def test_invalid_read_only_fields_are_rejected
    base = {"level" => "green", "confidence" => 0.99, "read_only" => "read_only_supported", "read_only_confidence" => 0.95}
    [base.merge("read_only" => "unknown"), base.merge("read_only_confidence" => 2),
     base.reject { |key, _| key == "read_only" }].each do |args|
      assessor = RobotOnRails::Providers::LLMRisk.new(@config, provider: FakeProvider.new(reply(args)))
      assert_raises(RobotOnRails::Error) { assessor.assess(**@state) }
    end
  end

  def test_jev_selection_does_not_call_llm
    jev = Object.new
    def jev.assess(**) = {level: :amber, confidence: 0.95}
    provider = FakeProvider.new
    llm = RobotOnRails::Providers::LLMRisk.new(@config, provider: provider)
    risk = RobotOnRails::Risk.new(system_one: jev, llm: llm, evidence: ->(_) { @evidence })
    assert_equal :amber, risk.assess("execute_ruby", {"code" => "Widget.count", "purpose" => "count"}).level
    assert_empty provider.requests
  end

  def test_proposer_schema_no_longer_requests_unevidenced_rating
    [true, false].each do |enabled|
      schema = RobotOnRails::Tools.definitions(system_one: enabled).find { |t| t[:name] == "execute_ruby" }
      refute schema[:parameters][:properties].key?("risk")
    end
  end

  def test_real_adapter_payload_and_response_parsing
    payloads = []
    transport = ->(payload) do
      payloads << payload
      {"status" => "completed", "output" => [{"type" => "function_call", "call_id" => "risk1", "name" => "report_risk",
        "arguments" => JSON.generate({"level" => "green", "confidence" => 0.9, "read_only" => "read_only_supported", "read_only_confidence" => 0.95})}]}
    end
    assessor = RobotOnRails::Providers::LLMRisk.new(@config, provider: RobotOnRails::Providers::OpenAI.new(@config, transport: transport))
    assert_equal :green, assessor.assess(**@state)[:level]
    assert_equal({type: "function", name: "report_risk"}, payloads.first[:tool_choice])
    assert payloads.first[:tools].first[:strict]
    assert_equal false, payloads.first[:store]
  end
end
