# frozen_string_literal: true
require_relative "test_helper"

class RiskDebugTest < Minitest::Test
  class TTY < StringIO
    def tty? = true
  end

  def setup
    config = RailsAI::Config.new({"SYSTEM_ONE_KEY" => "saved-secret-key", "SYSTEM_ONE_URL" => "https://example.test/risk", "SYSTEM_ONE_MODEL" => "jev-latest"}, load_saved: false)
    @redactor = RailsAI::Redactor.new({}, secrets: ["saved-secret-key"])
    @requests = []
    @answer = {"type" => "choice", "choice" => "green", "confidence" => 0.56,
      "probabilities" => {"green" => 0.7, "amber" => 0.28, "red" => 0.02}}
    service = RailsAI::Providers::SystemOne.new(config, redactor: @redactor, transport: ->(payload) {
      @requests << payload
      {"model" => "jev-resolved-version", "answers" => {"risk" => @answer, "read_only" => {"type" => "choice", "choice" => "insufficient_evidence", "confidence" => 0.9, "probabilities" => {"read_only_supported" => 0.1, "changes_or_external_effects" => 0.0, "insufficient_evidence" => 0.9}}}, "usage" => {"input_tokens" => 42}}
    })
    @risk = RailsAI::Risk.new(system_one: service, redactor: @redactor,
      evidence: ->(code) { {"status" => "observed", "code" => code, "source_excerpt" => "saved-secret-key"} })
    @args = {"code" => "User.count", "purpose" => "Count users"}
  end

  def test_debug_contains_exact_redacted_request_response_and_review_reason
    assessment = @risk.assess("execute_ruby", @args)
    assert assessment.force_review
    assert_includes assessment.reason, "green=0.700, amber=0.280, red=0.020"
    assert_includes assessment.reason, "threshold 0.80"
    report = JSON.parse(@risk.debug_json)
    refute report.key?("runtime_evidence")
    refute report.key?("local_signals")
    refute report.key?("decision")
    assert_equal 0.8, report["confidence_threshold"]
    assert_equal ["low_confidence"], report["review_reasons"]
    assert_equal JSON.parse(JSON.generate(@requests.first)), report["provider"]["request"]
    assert_equal @answer, report["provider"]["response"]["answer"]
    assert_equal "jev-resolved-version", report["provider"]["response"]["model"]
    refute_includes @risk.debug_json, "saved-secret-key"
    assert_includes @risk.debug_json, "[REDACTED]"
  end

  def test_details_at_review_do_not_reassess_or_approve
    output = StringIO.new
    terminal = RailsAI::Terminal.new(input: TTY.new("d\nd\nn\n"), output: output)
    assert_nil terminal.review(name: "execute_ruby", arguments: @args, environment: "development", appetite: 1, risk: @risk)
    assert_equal 1, @requests.length
    assert_includes output.string, "confidence_threshold"
  end

  def test_private_export_refuses_overwrite_and_symlinks
    @risk.assess("execute_ruby", @args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "risk.json")
      @risk.export_debug(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal JSON.parse(@risk.debug_json), JSON.parse(File.read(path))
      assert_raises(RailsAI::Error) { @risk.export_debug(path) }
      link = File.join(dir, "link.json")
      File.symlink(path, link)
      assert_raises(RailsAI::Error) { @risk.export_debug(link) }
    end
  end

  def test_new_assessment_replaces_previous_provider_details_on_evidence_failure
    calls = 0
    evidence = ->(_) { calls += 1; raise RailsAI::Error, "evidence unavailable" if calls > 1; {"status" => "observed"} }
    service = Object.new
    def service.assess(**) = {level: :green, confidence: 0.95, read_only: "read_only_supported", read_only_confidence: 0.95 }
    def service.last_debug = {"request" => "old-request"}
    risk = RailsAI::Risk.new(system_one: service, evidence: evidence)
    risk.assess("execute_ruby", @args)
    risk.assess("execute_ruby", @args.merge("code" => "Topic.count"))
    report = JSON.parse(risk.debug_json)
    assert_equal "failed", report["status"]
    assert_equal "Topic.count", report["code"]
    refute report.key?("provider")
  end
end
