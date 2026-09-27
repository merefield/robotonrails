# frozen_string_literal: true
require "find"
require "digest"

module RobotOnRails
  class SourceIndex
    MAX_FILE_BYTES = 512 * 1024
    MAX_FILES = 10_000
    EXTENSIONS = %w[.rb .rake .md .yml .yaml .erb .js .gjs .ts].freeze
    EXCLUDED = %w[.git .bundle node_modules vendor tmp log storage coverage].freeze

    def initialize(roots)
      @roots = roots.to_h { |entry| [entry.fetch("id"), File.realpath(entry.fetch("path"))] }
    end

    def read(root:, path:, start_line:)
      base = @roots.fetch(root) { raise Error, "Unknown source root." }
      full = File.realpath(File.expand_path(path, base))
      raise Error, "Path is outside the source root." unless full.start_with?(base + File::SEPARATOR)
      raise Error, "This file is excluded from source inspection." unless allowed?(full, base)
      raise Error, "Source file exceeds #{MAX_FILE_BYTES} bytes." if File.size(full) > MAX_FILE_BYTES
      lines = []
      File.open(full, "rb") do |file|
        file.each_line.with_index(1) do |line, number|
          next if number < start_line
          break if lines.length >= 200
          lines << "#{number}: #{line.encode('UTF-8', invalid: :replace, undef: :replace).chomp}"
        end
      end
      { "root" => root, "path" => path, "sha256" => Digest::SHA256.file(full).hexdigest, "lines" => lines }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "Cannot read source: #{e.class.name.split('::').last}"
    end

    def search(query:, root:)
      raise Error, "Search query must not be empty." if query.strip.empty?
      selected = root.empty? ? @roots : { root => @roots.fetch(root) { raise Error, "Unknown source root." } }
      matches = []
      scanned = 0
      catch(:limit) do
        selected.each do |id, base|
          Find.find(base) do |path|
            if File.directory?(path)
              Find.prune if path != base && (File.symlink?(path) || EXCLUDED.include?(File.basename(path)))
              next
            end
            next if File.symlink?(path) || !allowed?(path, base) || File.size(path) > MAX_FILE_BYTES
            scanned += 1
            throw :limit if scanned > MAX_FILES
            File.foreach(path, mode: "rb").with_index(1) do |line, number|
              line = line.encode("UTF-8", invalid: :replace, undef: :replace)
              next unless line.include?(query)
              matches << { "root" => id, "path" => path.delete_prefix(base + "/"), "line" => number, "text" => line.strip[0, 500] }
              throw :limit if matches.length >= 50
            end
          rescue Errno::ENOENT, Errno::EACCES
            next
          end
        end
      end
      { "matches" => matches, "limit_reached" => matches.length >= 50 || scanned > MAX_FILES }
    end

    private

    def allowed?(path, base)
      relative = path.delete_prefix(base + "/")
      parts = relative.split(File::SEPARATOR)
      File.file?(path) && EXTENSIONS.include?(File.extname(path)) &&
        (parts & EXCLUDED).empty? && !relative.match?(/(?:\A|\/)(?:\.env|credentials|secrets|master\.key|database\.yml)/i)
    end
  end
end
