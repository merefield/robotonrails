# frozen_string_literal: true
gem "minitest", "~> 5.0"
ENV["MT_NO_PLUGINS"] = "1"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "robotonrails"

class FakeTerminal
  attr_reader :messages, :approvals
  attr_accessor :approve_result
  def initialize
    @messages, @approvals = [], []
    @approve_result = false
  end
  def say(text) = @messages << text
  def assistant(text) = @messages << text
  def status(text) = @messages << text
  def result(value) = @messages << value
  def review(**args)
    @approvals << args
    args[:name] != "execute_ruby" || @approve_result ? args[:arguments] : nil
  end
end

class FakeWorker
  attr_reader :calls, :stopped
  attr_accessor :response
  def initialize
    @calls = []
    @response = { "status" => "ok", "result" => { "value" => "42" } }
  end
  def inventory = { "application" => "Test", "environment" => "test" }
  def call(name, args)
    @calls << [name, args]
    @response
  end
  def stop = @stopped = true
end

class FakeProvider
  attr_reader :requests
  def initialize(*responses)
    @responses, @requests = responses, []
  end
  def complete(**request)
    @requests << Marshal.load(Marshal.dump(request))
    response = @responses.shift
    raise response if response.is_a?(Exception)
    response || { "kind" => "assistant", "text" => "Done.", "calls" => [], "continuation" => [] }
  end
end
