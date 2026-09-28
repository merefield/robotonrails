# frozen_string_literal: true
require_relative "test_helper"
require "robotonrails/console"
require "pry"
require "pty"
require "timeout"

class PryConsoleTest < Minitest::Test
  def test_tracks_current_binding_and_restores_nested_sessions
    RobotOnRails::Console.install_pry!
    outer = Pry.new(output: StringIO.new)
    inner = Pry.new(output: StringIO.new)
    outer.push_binding(Object.new)
    inner.push_binding(Object.new)
    outer.current_binding.local_variable_set(:inner, inner)
    outer.evaluate_ruby(<<~'CODE')
      captured = RobotOnRails::Console.current_binding
      inner.evaluate_ruby('captured = RobotOnRails::Console.current_binding')
      restored = RobotOnRails::Console.current_pry.equal?(pry_instance)
    CODE
    assert_same outer.current_binding, outer.current_binding.local_variable_get(:captured)
    assert_same inner.current_binding, inner.current_binding.local_variable_get(:captured)
    assert outer.current_binding.local_variable_get(:restored)
    assert_nil RobotOnRails::Console.current_pry
    assert_raises(RuntimeError) { outer.evaluate_ruby('raise "test failure"') }
    assert_nil RobotOnRails::Console.current_pry
    outer.push_binding(Object.new)
    outer.evaluate_ruby('captured = RobotOnRails::Console.current_binding')
    assert_same outer.current_binding, outer.current_binding.local_variable_get(:captured)
  end

  def test_unsupported_pry_input_does_not_queue
    RobotOnRails::Console.install_pry!
    pry = Pry.new(input: StringIO.new, output: StringIO.new)
    pry.push_binding(Object.new)
    pry.evaluate_ruby('queued = RobotOnRails::Console::InputHandoff.new.queue("raise \"must not execute\"")')
    assert_equal false, pry.current_binding.local_variable_get(:queued)
  end

  def test_pry_prefill_can_be_edited_before_execution
    exercise_pry("\u0001\u000b$ror_result = 2\n", "RESULT=2")
  end

  def test_pry_prefill_can_be_cancelled
    exercise_pry("\u0003", "RESULT=0")
  end

  private

  def exercise_pry(submission, expected)
    script = <<~'CODE'
      require "robotonrails/console"
      require "pry"
      RobotOnRails::Console.install!
      Pry.config.history_save = false
      Pry.config.history_load = false
      Pry.config.color = false
      $ror_result = 0
      Pry.start(TOPLEVEL_BINDING, prompt: Pry::Prompt.new("test", "test", [proc { "READY> " }, proc { "MORE> " }]))
      puts "RESULT=#{$ror_result}"
    CODE
    output = +""
    PTY.spawn({"TERM" => "xterm"}, RbConfig.ruby, "-Ilib", "-e", script) do |reader, writer, pid|
      begin
        phase = 0
        Timeout.timeout(15) do
          until output.include?("RESULT=")
            chunk = reader.readpartial(4096)
            output << chunk
            writer.write("\e[1;1R") if chunk.include?("\e[6n")
            if phase == 0 && output.include?("READY> ")
              # Split the candidate string so its echo cannot be mistaken for prefill.
              writer.write('RobotOnRails::Console::InputHandoff.new.queue("$ror_" + "result = 1")' + "\n")
              output.clear
              phase = 1
            elsif phase == 1 && output.include?("$ror_result = 1")
              refute_includes output, "RESULT="
              writer.write(submission)
              output.clear
              phase = 2
            elsif phase == 2 && output.include?("READY> ")
              writer.write("exit-all\n")
              phase = 3
            end
          end
        end
        assert_includes output, expected
      rescue Errno::EIO, Timeout::Error
        flunk output
      ensure
        Process.kill("TERM", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
