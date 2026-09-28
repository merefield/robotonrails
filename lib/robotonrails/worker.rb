# frozen_string_literal: true
# Private subprocess entry point; protocol responses use FD 3, never stdout.
# Activate the host bundle before RobotOnRails can load any versioned dependencies.
begin
  gemfile = File.join(ENV.fetch("ROBOTONRAILS_APP"), "Gemfile")
  if File.file?(gemfile)
    ENV["BUNDLE_GEMFILE"] = gemfile
    require "bundler/setup"
  end
  require_relative "../robotonrails"
rescue LoadError, StandardError => e
  STDERR.puts("Rails worker bootstrap failed: #{e.class}: #{e.message}")
  exit 1
end

module RobotOnRails
  class Worker
    MAX_REQUEST = 64 * 1024
    MAX_RESPONSE = 48 * 1024

    def self.run
      protocol = IO.new(3, "w")
      protocol.sync = true
      STDOUT.sync = STDERR.sync = true
      root = ENV.fetch("ROBOTONRAILS_APP")
      Dir.chdir(root)
      require File.join(root, "config/environment.rb")
      raise Error, "Rails application failed to load." unless defined?(Rails) && Rails.application
      Rails.application.eager_load!
      runtime = Runtime.new(root)
      send_result(protocol, { "status" => "ready", "inventory" => runtime.discovery.inventory })
      while (line = STDIN.gets(MAX_REQUEST + 1))
        raise Error, "Request too large." if line.bytesize > MAX_REQUEST || !line.end_with?("\n")
        request = JSON.parse(line)
        name, args = request.values_at("name", "arguments")
        begin
          value = runtime.call(name, args)
          send_result(protocol, { "status" => "ok", "result" => value })
        rescue StandardError, SyntaxError => e
          send_result(protocol, { "status" => "error", "error" => "#{e.class}: #{e.message}"[0, 4000],
            "outcome" => name == "execute_ruby" ? "Changes may have occurred before this error; inspect before retrying." : nil })
        end
      end
    rescue StandardError, SyntaxError, LoadError => e
      send_result(protocol, { "status" => "boot_error", "error" => "#{e.class}: #{e.message}"[0, 4000] }) if protocol
    ensure
      protocol&.close
    end

    def self.send_result(protocol, result)
      json = JSON.generate(result)
      if json.bytesize > MAX_RESPONSE
        json = JSON.generate({ "status" => "error", "error" => "Result exceeds 48 KiB. Narrow the query or source range." })
      end
      protocol.puts(json)
    end
  end
end

RobotOnRails::Worker.run if $PROGRAM_NAME == __FILE__
