# frozen_string_literal: true
require_relative "test_helper"

class RiskExplanationTest < Minitest::Test
  class TTY < StringIO
    def tty? = true
  end

  def setup
    @config = RailsAI::Config.new({}, load_saved: false)
    @provider = FakeProvider.new({"calls" => [{"name" => "explain_review", "arguments" => {
      "basis" => "missing_evidence", "explanation" => "The chained receiver is unresolved; no write is shown."}}],
      "usage" => {"input_tokens" => 30, "output_tokens" => 12}})
    @explainer = RailsAI::Providers::RiskExplanation.new(@config, provider: @provider,
      redactor: RailsAI::Redactor.new({}, secrets: ["saved-secret-key"]))
    @service = Object.new
    def @service.assess(**) = {level: :green, confidence: 0.51}
    @risk = RailsAI::Risk.new(system_one: @service, explainer: @explainer,
      evidence: ->(_) { {"status" => "observed", "calls" => [{"receiver" => "(dynamic)", "status" => "unresolved"}], "source" => "saved-secret-key"} })
    @args = {"code" => "User.real.count", "purpose" => "Count requested real users"}
  end

  def test_explanation_is_grounded_redacted_and_cannot_change_assessment
    assessment = @risk.assess("execute_ruby", @args)
    explanation = @risk.explain_review
    assert_includes explanation, "chained receiver"
    assert_equal :green, assessment.level
    assert assessment.force_review
    refute @risk.automatic?(assessment, 1)
    request = @provider.requests.first
    state = JSON.parse(request[:events].first["text"])
    assert_equal 0.51, state["decision"]["confidence"]
    assert_equal "[REDACTED]", state["runtime_evidence"]["source"]
    assert_equal ["explain_review"], request[:tools].map { |tool| tool[:name] }
    assert_equal({type: "function", name: "explain_review"}, request[:tool_choice])
    @risk.explain_review
    assert_equal 1, @provider.requests.length
    assert_equal 30, @explainer.usage["input_tokens"]
    assert_equal "missing_evidence", JSON.parse(@risk.debug_json)["explanation"]["basis"]
  end

  def test_terminal_explains_once_and_details_do_not_requery
    output = StringIO.new
    terminal = RailsAI::Terminal.new(input: TTY.new("d\nn\n"), output: output)
    assert_nil terminal.review(name: "execute_ruby", arguments: @args, environment: "development", appetite: 1, risk: @risk)
    assert_includes output.string, "Why review (LLM): The chained receiver"
    assert_equal 1, @provider.requests.length
  end

  def test_auto_run_does_not_request_explanation
    def @service.assess(**) = {level: :green, confidence: 0.99, read_only: "read_only_supported", read_only_confidence: 0.95 }
    terminal = RailsAI::Terminal.new(input: TTY.new(""), output: StringIO.new)
    assert_equal @args, terminal.review(name: "execute_ruby", arguments: @args, environment: "development", appetite: 1, risk: @risk)
    assert_empty @provider.requests
  end

  def test_explanation_failure_preserves_review_and_is_not_retried
    provider = FakeProvider.new(RailsAI::Error.new("service unavailable"))
    explainer = RailsAI::Providers::RiskExplanation.new(@config, provider: provider)
    risk = RailsAI::Risk.new(system_one: @service, explainer: explainer, evidence: ->(_) { {"status" => "observed"} })
    assessment = risk.assess("execute_ruby", @args)
    assert_includes risk.explain_review, "Explanation unavailable"
    assert_equal :green, assessment.level
    assert assessment.force_review
    risk.explain_review
    assert_equal 1, provider.requests.length
  end

  def test_invalid_explanation_is_rejected
    provider = FakeProvider.new({"calls" => [{"name" => "execute_ruby", "arguments" => {}}]})
    explainer = RailsAI::Providers::RiskExplanation.new(@config, provider: provider)
    assert_raises(RailsAI::Error) { explainer.explain({}) }
  end
end
