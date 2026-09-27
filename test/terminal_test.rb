# frozen_string_literal: true
require_relative "test_helper"

class TerminalTest < Minitest::Test
  class TTY < StringIO
    def tty? = true
  end

  def review(input, code: "Widget.count", risk: "green", appetite: 1, environment: "test", assessor: RailsAI::Risk.new)
    @output = StringIO.new
    @terminal = RailsAI::Terminal.new(input: input, output: @output, error: StringIO.new)
    @terminal.review(name: "execute_ruby", arguments: { "code" => code, "purpose" => "test", "risk" => risk },
                     environment: environment, appetite: appetite, risk: assessor)
  end

  def test_compact_risk_line_keeps_low_confidence_review_and_visible_code
    service = Object.new
    def service.assess(**) = {level: :green, confidence: 0.57, probabilities: {"green" => 0.71, "amber" => 0.29, "red" => 0.0}}
    risk = RailsAI::Risk.new(system_one: service, evidence: ->(_) { {"status" => "observed"} })
    assert_nil review(TTY.new("n\n"), assessor: risk)
    lines = @output.string.lines
    assert_equal 1, lines.count { |line| line.include?("●") }
    assert_includes @output.string, "● GREEN · Jev · unavailable · category confidence ?% · review"
    assert_includes @output.string, "Widget.count"
    refute_includes @output.string, "Probabilities:"
    refute_includes @output.string, "Runtime evidence:"
    refute_includes @output.string, "execute_ruby ·"
  end

  def test_auto_inspection_is_quiet_by_default_and_visible_with_verbose
    output, error = StringIO.new, StringIO.new
    terminal = RailsAI::Terminal.new(input: TTY.new(""), output: output, error: error)
    args = {"query" => "User"}
    assert_equal args, terminal.review(name: "models", arguments: args, environment: "development", appetite: 1)
    assert_empty output.string
    assert_empty error.string
    terminal.verbose = true
    assert_equal args, terminal.review(name: "models", arguments: args, environment: "development", appetite: 1)
    assert_equal 1, output.string.lines.length
    assert_includes output.string, 'Inspecting models: {"query":"User"}'
    refute_includes output.string, "●"
  end

  def test_quiet_mode_preserves_required_inspection_approval
    output = StringIO.new
    terminal = RailsAI::Terminal.new(input: TTY.new("n\n"), output: output)
    assert_nil terminal.review(name: "models", arguments: {"query" => "User"}, environment: "development", appetite: 0)
    assert_includes output.string, "models"
    assert_includes output.string, "Inspect? [y/N]"
  end

  def test_default_enter_declines
    assert_nil review(TTY.new("\n"))
    assert_includes @output.string, "AMBER"
  end

  def test_edit_reassesses_and_executes_exact_replacement
    result = review(TTY.new("e\nWidget.delete_all\n.end\ny\nexecute\n"))
    assert_equal "Widget.delete_all", result["code"]
    refute result.key?("risk")
    assert_includes @output.string, "RED"
  end

  def test_red_requires_second_confirmation_even_at_appetite_two
    assert_nil review(TTY.new("y\nno\n"), code: "Widget.delete_all", appetite: 2)
    assert review(TTY.new("y\nexecute\n"), code: "Widget.delete_all", appetite: 2)
  end

  def test_production_confirmation_names_environment
    assert_nil review(TTY.new("y\nexecute\n"), environment: "production")
    assert review(TTY.new("y\nexecute production\n"), environment: "production")
  end

  def test_auto_amber_requires_tty
    assert review(TTY.new(""), appetite: 2)
    assert_nil review(StringIO.new("y\n"), appetite: 2)
  end

  def test_jev_rechecks_edited_code
    service = Object.new
    service.instance_variable_set(:@codes, [])
    def service.assess(code:, **)
      @codes << code
      { level: :amber, confidence: 0.99 }
    end
    review(TTY.new("e\nWidget.first\n.end\ny\n"), assessor: RailsAI::Risk.new(system_one: service))
    assert_equal ["Widget.count", "Widget.first"], service.instance_variable_get(:@codes)
  end

  def test_control_characters_cannot_hide_command_text
    review(TTY.new("\n"), code: "puts \"\e[2J\"", risk: "amber")
    refute_includes @output.string, "\e"
    assert_includes @output.string, "\\u001b"
  end
end
