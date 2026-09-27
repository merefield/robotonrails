# frozen_string_literal: true
require_relative "test_helper"

class ReadOnlyTest < Minitest::Test
  def assessment(level: :green, confidence: 0.5, read_only: "read_only_supported", read_only_confidence: 0.95, environment: "development", evidence: "observed", code: "Widget.count")
    decision = {level: level, confidence: confidence, read_only: read_only, read_only_confidence: read_only_confidence}
    service = Object.new
    service.define_singleton_method(:assess) { |**| decision }
    risk = RobotOnRails::Risk.new(system_one: service, environment: environment, evidence: ->(_) { {"status" => evidence} })
    [risk, risk.assess("execute_ruby", {"code" => code, "purpose" => "test"})]
  end

  def test_read_only_judgment_can_authorize_low_colour_confidence_without_changing_colour
    [:green, :amber].each do |level|
      risk, result = assessment(level: level)
      assert risk.automatic?(result, 1)
      assert_equal level, result.level
      assert_empty JSON.parse(risk.debug_json)["review_reasons"]
      assert risk.automatic?(result, 2), "higher appetite also permits supported reads"
    end
  end

  def test_summary_names_selected_category_without_claiming_probability_of_read_only
    risk, result = assessment(read_only: "insufficient_evidence", read_only_confidence: 0.39)
    refute risk.automatic?(result, 1)
    assert_equal "Jev · insufficient_evidence · category confidence 39%", result.summary
  end

  def test_unsupported_category_is_not_a_confidence_threshold_failure
    [0.28, 0.99].each do |confidence|
      risk, result = assessment(read_only: "insufficient_evidence", read_only_confidence: confidence)
      refute risk.automatic?(result, 1)
      assert_equal ["read_only_not_supported"], JSON.parse(risk.debug_json)["review_reasons"]
    end
    risk, result = assessment(read_only_confidence: 0.28)
    refute risk.automatic?(result, 1)
    assert_equal ["low_read_only_confidence"], JSON.parse(risk.debug_json)["review_reasons"]
  end

  def test_review_guards
    [{level: :red}, {read_only_confidence: 0.79}, {read_only: "insufficient_evidence"},
     {read_only: "changes_or_external_effects", code: "Widget.create!; Widget.count"},
     {environment: "production"}, {evidence: "unavailable"}].each do |options|
      risk, result = assessment(**options)
      refute risk.automatic?(result, 1), options.inspect
    end
    risk, result = assessment
    refute risk.automatic?(result, 0)
  end

  def test_missing_new_provider_answer_cannot_authorize
    config = RobotOnRails::Config.new({}, load_saved: false)
    config.system_one_url = "https://api.typesafe.ai/v1/systemone"
    provider = RobotOnRails::Providers::SystemOne.new(config, transport: ->(_) {
      {"answers" => {"risk" => {"type" => "choice", "choice" => "green", "confidence" => 0.99,
        "probabilities" => {"green" => 1.0, "amber" => 0.0, "red" => 0.0}}}}
    })
    risk = RobotOnRails::Risk.new(system_one: provider, evidence: ->(_) { {"status" => "observed"} })
    result = risk.assess("execute_ruby", {"code" => "Widget.count", "purpose" => "count"})
    refute risk.automatic?(result, 1)
    assert result.force_review
  end
end
