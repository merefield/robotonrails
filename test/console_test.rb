# frozen_string_literal: true
require_relative "test_helper"
require "open3"
require "robotonrails/console"

class ConsoleTest < Minitest::Test
  def test_install_preserves_private_existing_method_and_is_idempotent
    receiver = Object.new
    receiver.singleton_class.class_eval { private; def rai(*) = :original }
    refute RobotOnRails::Console.install!(receiver, output: StringIO.new)
    assert_equal :original, receiver.send(:rai)
    receiver = Object.new
    assert RobotOnRails::Console.install!(receiver)
    assert RobotOnRails::Console.install!(receiver)
    assert_equal 1, receiver.singleton_class.ancestors.count(RobotOnRails::Console::Helper)
  end

  def test_in_process_console_in_real_rails_app
    script = <<~'CODE'
      require "robotonrails"
      require File.expand_path("test/fixtures/app/config/environment", Dir.pwd)
      require "robotonrails/console"
      require "stringio"
      require "irb"
      def check(value, message)
        raise message unless value
      end
      class TTY < StringIO
        def tty? = true
      end
      class Provider
        attr_reader :requests
        def initialize(*responses)
          @responses, @requests = responses, []
        end
        def complete(**args)
          @requests << Marshal.load(Marshal.dump(args))
          response = @responses.shift
          raise response if response.is_a?(Exception)
          response
        end
      end
      def command(code, id)
        {"kind" => "assistant", "text" => "", "calls" => [{"id" => id, "name" => "execute_ruby", "arguments" => {"code" => code, "purpose" => "test"}}]}
      end
      def done
        {"kind" => "assistant", "text" => "Done", "calls" => []}
      end
      config = RobotOnRails::Config.new({}, load_saved: false)
      output = StringIO.new
      provider = Provider.new(command("draft.name", "one"), done, command("draft.name + ' again'", "two"), done,
        command("draft.name = 'modified'", "decline"), command("raise 'fixture failure'", "error"), done)
      input = TTY.new("y\ny\nn\ny\n")
      session = RobotOnRails::Console::Session.new(config: config, provider: provider,
        terminal: RobotOnRails::Terminal.new(input: input, output: output, error: StringIO.new), risk: RobotOnRails::Risk.new)
      draft = Widget.new(name: "unsaved")
      check(session.ask("inspect draft", context: binding).nil?, "helper must return nil")
      session.ask("repeat that")
      events = provider.requests[2][:events]
      check(events.any? { |e| e["kind"] == "tool" && e.dig("result", "result", "value") == '"unsaved"' }, "prior result absent")
      check(output.string.include?('unsaved again'), "binding not retained")
      session.ask("change draft")
      check(draft.name == "unsaved", "declined code executed")
      session.ask("cause error")
      check(output.string.include?("fixture failure"), "exception not reported")
      session.reset
      session.ask("after reset")
      check(provider.requests.last[:events].length == 1, "history not reset")
      adapter = RobotOnRails::Console::Adapter.new(Rails.root.to_s)
      adapter.runtime.context = binding
      check(adapter.call("execute_ruby", {"code" => "draft.name", "purpose" => "inspect"}).dig("result", "value") == '"unsaved"', "unsaved binding unavailable")
      check(adapter.call("execute_ruby", {"code" => "raise 'oops'", "purpose" => "error"})["status"] == "error", "error escaped")
      check(adapter.call("execute_ruby", {"code" => "1 + 1", "purpose" => "continue"}).dig("result", "value") == "2", "console unusable after error")
      interrupted = RobotOnRails::Console::Session.new(config: config, provider: Provider.new(command("raise Interrupt", "interrupt")),
        terminal: RobotOnRails::Terminal.new(input: TTY.new("y\n"), output: output, error: StringIO.new), risk: RobotOnRails::Risk.new)
      check(interrupted.ask("interrupt").nil?, "interrupt escaped console helper")
      check(output.string.include?("Console remains active"), "interrupt not explained")
      IRB.setup(nil, argv: [])
      irb = IRB::Irb.new
      IRB.conf[:MAIN_CONTEXT] = irb.context
      check(RobotOnRails::Console.current_binding.equal?(irb.context.workspace.binding), "native binding detection failed")
      check(RobotOnRails::Console.install!(irb.context.workspace.binding.receiver), "IRB helper not installed")
      check(irb.context.workspace.binding.eval("respond_to?(:rai)"), "rai absent from IRB workspace")
      puts "CONSOLE_OK"
    CODE
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: File.expand_path("..", __dir__))
    assert status.success?, output
    assert_includes output, "CONSOLE_OK"
  end
end
