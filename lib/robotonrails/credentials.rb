# frozen_string_literal: true
require "open3"
require "timeout"
require "securerandom"

module RobotOnRails
  class SecretService
    def initialize(env = ENV, runner: nil)
      @executable = env.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "secret-tool") }
                       .find { |file| File.file?(file) && File.executable?(file) }
      @runner = runner || method(:run)
    end

    def available?
      !@executable.nil?
    end

    def store(id, text)
      invoke(["store", "--label=RobotOnRails API keys", "application", "robotonrails", "credential_id", id], text)
    end

    def lookup(id)
      invoke(["lookup", "application", "robotonrails", "credential_id", id], nil)
    end

    private

    def invoke(args, input)
      raise Error, "OS credential store unavailable. Install libsecret-tools or rerun robotonrails setup to choose file storage." unless available?
      output, success = @runner.call(@executable, args, input)
      raise Error, "OS credential store is locked or unavailable. Unlock it or rerun robotonrails setup." unless success
      output
    end

    def run(executable, args, input)
      stdin, stdout, stderr, waiter = Open3.popen3(executable, *args, pgroup: true)
      output = Timeout.timeout(15) do
        stdin.write(input) if input
        stdin.close
        text = stdout.read(16_385)
        raise Error, "OS credential response exceeded its size limit." if text.bytesize > 16_384
        # Never expose helper output or include secrets in process arguments/errors.
        [text, waiter.value.success?]
      end
      output
    rescue Timeout::Error, SystemCallError, IOError
      raise Error, "OS credential store did not respond. Unlock it or rerun robotonrails setup."
    ensure
      if waiter && waiter.alive?
        begin
          Process.kill("KILL", -waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join
      end
      [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
    end
  end

  class Credentials
    NAMES = %w[openai_api_key system_one_key].freeze

    def initialize(store, settings, service: SecretService.new)
      @store, @settings, @service = store, settings, service
    end

    def fetch(name)
      values[name]
    end

    def values
      return @values if @values
      backend = @settings["credential_backend"]
      return @values = {} unless backend
      text = if backend == "secret_service"
        id = @settings["credential_id"]
        raise Error, "Missing OS credential identifier. Run robotonrails setup." if id.to_s.empty?
        @service.lookup(id)
      else
        @store.read("credentials.json", private: true)
      end
      raise Error, "Saved credentials are missing. Run robotonrails setup." if text.to_s.empty?
      @values = JSON.parse(text)
      self.class.validate!(@values)
      @values
    rescue JSON::ParserError
      raise Error, "Invalid RobotOnRails credentials.json. Run robotonrails setup to replace it."
    end

    def self.validate!(values)
      valid = values.is_a?(Hash) && (values.keys - NAMES).empty? && values.values.all? do |value|
        value.is_a?(String) && !value.empty? && value.bytesize <= 4096 && !value.match?(/[\x00-\x20\x7f]/)
      end
      raise Error, "Invalid saved API credentials. Run robotonrails setup." unless valid
    end
  end
end
