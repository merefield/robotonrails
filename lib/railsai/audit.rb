# frozen_string_literal: true
require "time"
require "digest"

module RailsAI
  # Opt-in action metadata only: no code, record output, prompts or credentials.
  class Audit
    def initialize(path)
      @io = File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600)
      raise Error, "Audit path must be a regular file owned by this user." unless @io.stat.file? && @io.stat.uid == Process.uid
      @io.chmod(0o600)
      @io.sync = true
    end

    def record(name:, arguments:, result:)
      event = { time: Time.now.utc.iso8601, tool: name,
                arguments_sha256: Digest::SHA256.hexdigest(JSON.generate(arguments)), status: result["status"] }
      @io.flock(File::LOCK_EX)
      @io.puts(JSON.generate(event))
    ensure
      @io.flock(File::LOCK_UN) if @io
    end

    def close
      @io.close
    end
  end
end
