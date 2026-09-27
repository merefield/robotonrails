# frozen_string_literal: true
require "yaml"
require "fileutils"
require "tempfile"

module RobotOnRails
  class SettingsStore
    KEYS = %w[version root environment model llm_url reasoning_effort max_output_tokens api_timeout risk_appetite system_one_enabled system_one_url system_one_model credential_backend credential_id].freeze
    attr_reader :directory

    def initialize(env = ENV, directory: nil)
      base = env["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
      @directory = File.expand_path(directory || env["ROBOTONRAILS_CONFIG_DIR"] || File.join(base, "robotonrails"))
    end

    def path(name)
      File.join(directory, name)
    end

    def settings
      text = read("config.yml")
      return {} unless text
      data = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
      validate_settings!(data)
      data
    rescue Psych::Exception
      raise Error, "Invalid RobotOnRails config.yml. Use plain YAML settings, without Ruby objects or aliases."
    end

    def validate_settings!(data)
      raise Error, "RobotOnRails config.yml must contain a settings mapping." unless data.is_a?(Hash)
      raise Error, "Unknown fields in RobotOnRails config.yml." unless (data.keys - KEYS).empty?
      data.each do |key, value|
        valid = case key
                when "version" then value == 1
                when "reasoning_effort" then Config::REASONING_EFFORTS.include?(value)
                when "max_output_tokens", "api_timeout" then value.is_a?(Integer) && value.positive?
                when "risk_appetite" then [0, 1, 2].include?(value)
                when "system_one_enabled" then value == true || value == false
                when "credential_backend" then %w[file secret_service].include?(value)
                else value.is_a?(String) && value.bytesize <= 4096 && !value.match?(/[\x00-\x1f\x7f]/)
                end
        raise Error, "Invalid #{key} in RobotOnRails config.yml." unless valid
      end
    end

    def read(name, private: false)
      file = path(name)
      return nil unless File.exist?(file) || File.symlink?(file)
      validate_directory! if File.exist?(directory) || File.symlink?(directory)
      File.open(file, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        stat = io.stat
        raise Error, "RobotOnRails #{name} must be a regular file owned by you." unless stat.file? && stat.uid == Process.uid
        raise Error, "RobotOnRails #{name} must have owner-only permissions (chmod 600)." if private && (stat.mode & 0o077) != 0
        raise Error, "RobotOnRails #{name} must not be writable by other users." unless (stat.mode & 0o022).zero?
        text = io.read(65_537)
        raise Error, "RobotOnRails #{name} exceeds 64 KiB." if text.bytesize > 65_536
        text
      end
    rescue Errno::ELOOP
      raise Error, "RobotOnRails #{name} must not be a symlink."
    end

    def write(name, text)
      FileUtils.mkdir_p(directory, mode: 0o700)
      validate_directory!
      File.chmod(0o700, directory)
      raise Error, "RobotOnRails #{name} must not be a symlink." if File.symlink?(path(name))
      Tempfile.create([".#{name}", ".tmp"], directory) do |file|
        file.chmod(0o600)
        file.write(text)
        file.flush
        file.fsync
        File.rename(file.path, path(name))
      end
    end

    def save(settings)
      validate_settings!(settings)
      write("config.yml", YAML.dump(settings))
    end

    private

    def validate_directory!
      stat = File.lstat(directory)
      raise Error, "RobotOnRails configuration directory must be a real directory owned by you." unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
      raise Error, "RobotOnRails configuration directory must not be writable by other users." unless (stat.mode & 0o022).zero?
    end
  end
end
