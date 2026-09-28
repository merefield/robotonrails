# frozen_string_literal: true
require_relative "test_helper"
require "robotonrails/console"
require "pty"
require "timeout"

class ConsoleHandoffTest < Minitest::Test
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

  def test_high_risk_is_queued_without_approval_menu_or_execution
    output, handoff = TTY.new, Handoff.new
    terminal = RobotOnRails::Console::ReviewTerminal.new(input: TTY.new, output: output, handoff: handoff)
    terminal.handoff_allowed = -> { true }
    error = assert_raises(RobotOnRails::DeferredExecution) do
      terminal.review(name: "execute_ruby", arguments: {"code" => "Widget.delete_all", "purpose" => "delete"}, environment: "production", appetite: 2)
    end
    assert_equal "Widget.delete_all", handoff.code
    assert_includes output.string, "PRODUCTION"
    assert_includes output.string, "not executed"
    refute_includes output.string, "[y]"
    assert_includes error.message, "unknown"
  end

  def test_other_binding_is_displayed_without_prefill_or_menu
    output, handoff = TTY.new, Handoff.new
    terminal = RobotOnRails::Console::ReviewTerminal.new(input: TTY.new, output: output, handoff: handoff)
    terminal.handoff_allowed = -> { false }
    assert_raises(RobotOnRails::DeferredExecution) do
      terminal.review(name: "execute_ruby", arguments: {"code" => "Widget.count", "purpose" => "count"}, environment: "test", appetite: 0)
    end
    assert_nil handoff.code
    assert_includes output.string, "Input prefill unavailable"
    refute_includes output.string, "[y]"
  end

  def test_low_risk_returns_command_for_immediate_execution
    service = Object.new
    def service.assess(**) = {level: :green, confidence: 0.99, read_only: "read_only_supported", read_only_confidence: 0.99}
    risk = RobotOnRails::Risk.new(system_one: service, evidence: ->(_) { {"status" => "observed"} })
    handoff = Handoff.new
    terminal = RobotOnRails::Console::ReviewTerminal.new(input: TTY.new, output: TTY.new, handoff: handoff)
    args = {"code" => "Widget.count", "purpose" => "count"}
    assert_equal args, terminal.review(name: "execute_ruby", arguments: args, environment: "test", appetite: 1, risk: risk)
    assert_nil handoff.code
  end

  def test_real_reline_prefill_preserves_multiline_ruby_and_waits_for_enter
    code = "first = 1\nfirst + 2"
    script = <<~RUBY
      require "robotonrails/console"
      require "reline"
      require "ripper"
      handoff = RobotOnRails::Console::InputHandoff.new
      def handoff.available? = true
      previous = proc { }
      Reline.pre_input_hook = previous
      handoff.queue(#{code.dump})
      value = Reline.readmultiline("native> ", false) { |input| !!Ripper.sexp(input) }
      puts "RECEIVED=" + value.dump
      puts "RESTORED=" + (Reline.pre_input_hook.equal?(previous)).to_s
    RUBY
    output = +""
    PTY.spawn({"TERM" => "dumb"}, RbConfig.ruby, "-Ilib", "-e", script) do |reader, writer, pid|
      begin
        sent = false
        Timeout.timeout(10) do
          until output.include?("RESTORED=true")
            chunk = reader.readpartial(4096)
            output << chunk
            writer.write("\e[1;1R") if chunk.include?("\e[6n")
            if !sent && output.include?("first + 2")
              refute_includes output, "RECEIVED="
              writer.write("\n")
              sent = true
            end
          end
        end
        assert_includes output, "RECEIVED=#{code.dump}"
      ensure
        Process.kill("TERM", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
