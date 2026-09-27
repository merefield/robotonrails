# frozen_string_literal: true
require_relative "test_helper"

class TerminalPresentationTest < Minitest::Test
  class TTY < StringIO
    def tty? = true
  end

  def setup
    @no_color = ENV.delete("NO_COLOR")
  end

  def teardown
    @no_color.nil? ? ENV.delete("NO_COLOR") : ENV["NO_COLOR"] = @no_color
  end

  def strip_ansi(text) = text.gsub(/\e\[[0-9;]*m/, "")

  def test_highlighting_preserves_multiline_code_and_exact_execution_argument
    code = "rows = Widget.where(name: 'literal **text**')\nrows.limit(1).pluck(:name)"
    output = TTY.new
    terminal = RobotOnRails::Terminal.new(input: TTY.new("y\n"), output: output)
    args = {"code" => code, "purpose" => "Inspect requested names", "risk" => "amber"}
    assert_equal args, terminal.review(name: "execute_ruby", arguments: args, environment: "test", appetite: 0)
    plain = strip_ansi(output.string)
    displayed = plain.lines.filter_map { |line| line.split("│ ", 2)[1]&.chomp }.join("\n")
    assert_equal code, displayed
    assert_operator plain.index(code.lines.first.chomp), :<, plain.index("● AMBER")
    assert_includes output.string, "\e[36mWidget"
    assert_includes plain, "[Enter] Cancel"
  end

  def test_single_line_has_no_number_and_no_color_disables_ansi
    ENV["NO_COLOR"] = "1"
    output, error = TTY.new, TTY.new
    terminal = RobotOnRails::Terminal.new(output: output, error: error)
    terminal.status("Thinking…")
    terminal.ruby_code("Widget.count")
    terminal.result({"status" => "ok", "result" => {"value" => "36"}})
    refute_includes output.string + error.string, "\e"
    assert_includes output.string, "  │ Widget.count"
    assert_includes output.string, "→ 36"
  end

  def test_progress_clears_before_visible_output_and_is_plain_when_redirected
    output, error = TTY.new, TTY.new
    terminal = RobotOnRails::Terminal.new(output: output, error: error)
    terminal.status("Thinking…")
    terminal.say("Proposal")
    assert error.string.end_with?("\r\e[2K")
    plain = StringIO.new
    RobotOnRails::Terminal.new(output: plain, error: plain).status("Thinking…")
    assert_equal "Thinking…\n", plain.string
  end

  def test_markdown_is_rendered_only_for_assistant_text_and_cannot_inject_controls
    output = StringIO.new
    terminal = RobotOnRails::Terminal.new(output: output)
    terminal.assistant("**Robert** uses `Widget.count`. [app/user.rb:4](app/user.rb#L4)\n```ruby\nputs '**literal**'\n```\n\e[2J")
    assert_includes output.string, "Robert uses Widget.count. app/user.rb:4"
    assert_includes output.string, "puts '**literal**'"
    assert_includes output.string, "\\u001b[2J"
    refute_includes output.string, "\e"
    terminal.result({"status" => "ok", "result" => {"value" => "**literal result**"}})
    assert_includes output.string, "**literal result**"
  end
end
