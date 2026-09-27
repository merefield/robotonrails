# frozen_string_literal: true
require "rbconfig"
require "thread"

module RobotOnRails
  class Capture
    LIMIT = 16 * 1024

    def initialize
      @mutex = Mutex.new
      clear
    end

    def clear
      @mutex.synchronize { @text = +""; @truncated = false }
    end

    def append(data)
      @mutex.synchronize do
        room = LIMIT - @text.bytesize
        @text << data.byteslice(0, [room, 0].max)
        @truncated = true if data.bytesize > room
      end
    end

    def text
      @mutex.synchronize { @text.encode("UTF-8", invalid: :replace, undef: :replace) + (@truncated ? "\n[output truncated]" : "") }
    end
  end

  class WorkerClient
    attr_reader :inventory

    def initialize(config, script: File.expand_path("worker.rb", __dir__))
      @config, @script = config, script
      @capture = Capture.new
    end

    def start
      stop
      input_read, @input = IO.pipe
      @responses, response_write = IO.pipe
      output_read, output_write = IO.pipe
      @capture.clear
      env = { "RAILS_ENV" => @config.environment, "ROBOTONRAILS_APP" => @config.root,
              "OPENAI_API_KEY" => nil, "ROBOTONRAILS_MODEL" => nil,
              "SYSTEM_ONE_KEY" => nil, "ROBOTONRAILS_SYSTEM_ONE_KEY" => nil }
      gemfile = File.join(@config.root, "Gemfile")
      env["BUNDLE_GEMFILE"] = gemfile if File.file?(gemfile)
      @pid = Process.spawn(env, RbConfig.ruby, @script, in: input_read, out: output_write, err: output_write,
                           3 => response_write, pgroup: true, chdir: @config.root)
      [input_read, response_write, output_write].each(&:close)
      @output_read = output_read
      hello = receive(@config.boot_timeout)
      raise WorkerError, "Rails boot failed: #{hello['error']}\n#{@capture.text}" unless hello["status"] == "ready"
      @inventory = hello.fetch("inventory")
      self
    rescue Exception
      [input_read, response_write, output_write, output_read].compact.each { |io| io.close unless io.closed? }
      stop
      raise
    end

    def call(name, args)
      raise WorkerError, "Rails worker is stopped. Use /restart." unless @pid
      Tools.validate!(name, args)
      @capture.clear
      @input.puts(JSON.generate({ name: name, arguments: args }))
      @input.flush
      response = receive(@config.timeout)
      response["output"] = @capture.text
      response
    rescue WorkerError, Errno::EPIPE, IOError => e
      stop
      raise WorkerError, "#{e.message} Worker stopped. Execution outcome may be unknown; check before retrying. Use /restart."
    rescue Interrupt
      stop
      raise
    end

    def stop
      if @pid
        begin
          Process.kill("KILL", -@pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(@pid)
        rescue Errno::ECHILD
          nil
        end
      end
      @pid = nil
      [@input, @responses, @output_read].compact.each { |io| io.close unless io.closed? }
    end

    private

    def drain_output(wait: 0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      256.times do
        break if @output_read.closed?
        chunk = @output_read.read_nonblock(4096, exception: false)
        if chunk == :wait_readable
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive? && IO.select([@output_read], nil, nil, remaining)
        elsif chunk.nil?
          @output_read.close
          break
        else
          @capture.append(chunk)
        end
      end
    end

    def receive(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      buffer = +""
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        streams = [@responses]
        streams << @output_read unless @output_read.closed?
        ready = IO.select(streams, nil, nil, [remaining, 0].max)
        raise WorkerError, "Rails worker timed out after #{seconds}s." if remaining <= 0 || !ready
        if ready[0].include?(@output_read)
          chunk = @output_read.read_nonblock(4096, exception: false)
          chunk.nil? ? @output_read.close : @capture.append(chunk) if chunk != :wait_readable
        end
        next unless ready[0].include?(@responses)
        buffer << @responses.readpartial(4096)
        raise WorkerError, "Worker response exceeded its limit." if buffer.bytesize > 64 * 1024
        break if buffer.end_with?("\n")
      end
      # Writes preceding the protocol response are already in the output pipe.
      # Drain them synchronously so results cannot race an output-capture thread.
      drain_output
      JSON.parse(buffer)
    rescue EOFError
      drain_output(wait: 0.2)
      raise WorkerError, "Rails worker exited. #{@capture.text}"
    rescue JSON::ParserError
      raise WorkerError, "Invalid worker response."
    end
  end
end
