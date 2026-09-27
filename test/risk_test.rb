# frozen_string_literal: true
require_relative "test_helper"

class RiskTest < Minitest::Test
  def args(code, risk = "green") = { "code" => code, "purpose" => "test", "risk" => risk }

  def test_read_looking_ruby_never_becomes_green
    assessment = RobotOnRails::Risk.new.assess("execute_ruby", args("Widget.count"))
    assert_equal :amber, assessment.level
  end

  def test_local_checks_escalate_llm_claims
    %w[Widget.delete_all Widget.update_all(active:false) File.read('/tmp/x') Kernel.eval('1')].each do |code|
      assert_equal :red, RobotOnRails::Risk.new.assess("execute_ruby", args(code)).level
    end
  end

  def test_risk_appetite_matrix
    assessor = RobotOnRails::Risk.new
    (0..2).each do |appetite|
      %i[green amber red].each do |level|
        assessment = RobotOnRails::Risk::Assessment.new(level: level)
        assert_equal(level != :red && (level == :green ? appetite >= 1 : appetite >= 2), assessor.automatic?(assessment, appetite))
      end
    end
  end

  def test_missing_llm_label_forces_review
    risk = RobotOnRails::Risk.new
    result = risk.assess("execute_ruby", { "code" => "42", "purpose" => "test" })
    assert result.force_review
    refute risk.automatic?(result, 2)
  end

  def test_jev_owns_rating_and_receives_evidence_even_when_local_signal_is_red
    service = Object.new
    def service.assess(**) = { level: :green, confidence: 0.99, read_only: "read_only_supported", read_only_confidence: 0.95 }
    risk = RobotOnRails::Risk.new(system_one: service, evidence: ->(_) { { "status" => "observed" } })
    assert_equal :green, risk.assess("execute_ruby", args("Widget.delete_all")).level
    def service.assess(**) = { level: :red, confidence: 0.99 }
    assert_equal :red, risk.assess("execute_ruby", args("Billing.settle")).level
  end

  def test_evidence_and_local_signals_are_sent_and_green_can_auto_run
    received = []
    service = Object.new
    service.define_singleton_method(:assess) { |**state| received << state; { level: :green, confidence: 0.9, read_only: "read_only_supported", read_only_confidence: 0.95 } }
    evidence = { "status" => "observed", "calls" => [{ "method" => "count" }] }
    risk = RobotOnRails::Risk.new(system_one: service, evidence: ->(_) { evidence })
    result = risk.assess("execute_ruby", args("Widget.count"))
    assert_equal :green, result.level
    assert risk.automatic?(result, 1)
    refute risk.automatic?(result, 0)
    assert_equal evidence, received.first[:evidence]
    assert_empty received.first[:local_signals]["matched_method_names"]
    refute received.first[:local_signals].key?("level")
    production = RobotOnRails::Risk.new(system_one: service, environment: "production", evidence: ->(_) { evidence })
    refute production.automatic?(production.assess("execute_ruby", args("Widget.count")), 2)
    unavailable = RobotOnRails::Risk.new(system_one: service).assess("execute_ruby", args("Widget.count"))
    assert unavailable.force_review
    assert_equal :green, unavailable.level
  end

  def test_low_confidence_and_outage_prevent_auto_run
    service = Object.new
    def service.assess(**) = { level: :green, confidence: 0.2 }
    risk = RobotOnRails::Risk.new(system_one: service, evidence: ->(_) { { "status" => "observed" } })
    result = risk.assess("execute_ruby", args("Widget.count"))
    assert result.force_review
    refute risk.automatic?(result, 2)
    def service.assess(**) = raise RobotOnRails::Error, "timeout"
    result = risk.assess("execute_ruby", args("Widget.count"))
    assert result.force_review
    assert_match(/timeout/, result.reason)
  end
end
