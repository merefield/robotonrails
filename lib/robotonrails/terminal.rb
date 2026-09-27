# frozen_string_literal: true
require "io/console"
require "ripper"

module RobotOnRails
  class Terminal
    attr_accessor :verbose

    def initialize(input: $stdin, output: $stdout, error: $stderr, verbose: false)
      @input, @output, @error = input, output, error
      @verbose = verbose
    end

    def interactive? = @input.tty?

    def secret(label)
      raise Error, "Hidden key entry requires an interactive terminal." unless interactive? && @input.respond_to?(:noecho)
      @output.print(clean(label))
      @output.flush
      begin
        if @output.tty? && @input.respond_to?(:raw)
          masked_secret
        else
          @input.noecho { @input.gets }&.chomp
        end
      ensure
        @output.puts
      end
    end

    def say(text)
      clear_progress
      @output.puts(clean(text))
    end

    def status(text)
      clear_progress
      if @error.tty? && @output.tty? && !ENV.key?("NO_COLOR") && text.match?(/\A(?:Thinking|Loading)/)
        @error.print(style(clean(text), 2, stream: @error))
        @error.flush
        @progress = true
      else
        @error.puts(clean(text))
      end
    end

    def clear_progress
      return unless @progress
      @error.print("\r\e[2K")
      @error.flush
      @progress = false
    end

    def assistant(text)
      clear_progress
      fenced = false
      clean(text).each_line do |line|
        if line.strip.start_with?("```")
          fenced = !fenced
          next
        end
        if fenced
          @output.puts("  " + style(line.chomp, 1))
        else
          heading = line.match?(/\A\#{1,6}\s+/)
          line = line.chomp.sub(/\A\#{1,6}\s+/, "")
          line = line.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
            label, target = Regexp.last_match(1), Regexp.last_match(2)
            target.split("#").first == label.split(":").first ? label : "#{label} (#{target})"
          end
          line = line.gsub(/`([^`]+)`|\*\*(.+?)\*\*|(?<!\*)\*([^*\n]+)\*(?!\*)/) do
            code, bold, italic = Regexp.last_match.captures
            style(code || bold || italic, italic ? 3 : 1)
          end
          @output.puts(heading ? style(line, 1) : line)
        end
      end
    end

    def prompt(label = "you> ")
      clear_progress
      if @input.equal?($stdin) && @output.equal?($stdout) && @input.tty? && @output.tty?
        begin
          require "reline"
          return Reline.readline(label, label == "you> ")
        rescue LoadError
          # Plain Ruby installations can still use the CLI without a line editor.
        end
      end
      @output.print(label)
      @output.flush
      @input.gets&.chomp
    end

    def review(name:, arguments:, environment:, appetite:, risk: Risk.new)
      args = arguments.dup
      edited = false
      loop do
        assessment = risk.assess(name, args)
        # Piped input cannot approve or auto-execute Ruby.
        automatic = risk.automatic?(assessment, appetite) && !(name == "execute_ruby" && environment == "production") && !edited && (name != "execute_ruby" || @input.tty?)
        if automatic && name != "execute_ruby"
          say("Inspecting #{name}: #{JSON.generate(args)}") if verbose
          return args
        end
        disposition = if automatic
          "auto"
        elsif name == "execute_ruby" && !@input.tty?
          "blocked: interactive terminal required"
        elsif name == "execute_ruby" && environment == "production"
          "review: production"
        elsif edited
          "review: edited"
        else
          "review"
        end
        if name == "execute_ruby"
          say("")
          @output.puts("  " + style(clean(args.fetch("purpose")), 2))
          @output.puts("  " + style("PRODUCTION", 31, 1)) if environment == "production"
          say("")
          ruby_code(args.fetch("code"))
          say("")
          label = case assessment.decision&.dig(:read_only)
          when "read_only_supported" then "Read-only"
          when "changes_or_external_effects" then "Changes or external effects"
          else "Effects uncertain"
          end
          disposition = automatic ? "Running automatically" : disposition.sub("review", "Approval required")
          traffic_light(assessment, detail: "#{label} · #{disposition}")
          if !automatic && (explanation = risk.explain_review)
            @output.puts("  " + clean(explanation))
          end
          @output.puts("  " + style(clean(assessment.summary), 2)) if verbose && assessment.summary
          say("") unless automatic
        else
          details = args.empty? ? "" : " #{JSON.generate(args)}"
          traffic_light(assessment, detail: "#{name}#{details} · #{disposition}")
        end
        return args if automatic
        return nil unless @input.tty?
        choice = nil
        loop do
          choice = prompt(name == "execute_ruby" ? "  [y] Execute   [e] Edit   [d] Details   [Enter] Cancel › " : "Inspect? [y/N]: ")
          break unless choice == "d" && name == "execute_ruby"
          say(risk.debug_json)
        end
        if choice == "e" && name == "execute_ruby"
          say("Enter replacement Ruby. Finish with .end on its own line; empty input cancels the edit.")
          lines = []
          while (line = prompt("ruby> "))
            break if line == ".end"
            lines << line
            break if lines.join("\n").bytesize > 16_384
          end
          return nil if line.nil?
          code = lines.join("\n")
          if code.bytesize > 16_384
            say("Edit exceeds 16 KiB; cancelled.")
            return nil
          end
          unless code.strip.empty?
            args["code"] = code
            args.delete("risk") # The original LLM label does not describe an edited command.
          end
          edited = true
          next
        end
        return nil unless choice == "y"
        if assessment.level == :red || (name == "execute_ruby" && environment == "production")
          expected = environment == "production" ? "execute production" : "execute"
          return nil unless prompt("Confirm #{assessment.level.to_s.upcase} action: type '#{expected}': ") == expected
        end
        return args
      end
    end

    def traffic_light(assessment, detail: assessment.summary || assessment.reason)
      clear_progress
      color = { green: 32, amber: 33, red: 31 }.fetch(assessment.level)
      badge = style("● #{assessment.level.to_s.upcase}", color, 1)
      @output.puts("  #{badge} · #{clean(detail).gsub("\n", " ")}")
    end

    def ruby_code(code)
      lines = code.lines
      width = lines.length.to_s.length
      lines.each_with_index do |line, index|
        gutter = lines.length > 1 ? "#{(index + 1).to_s.rjust(width)} │ " : "│ "
        tokens = Ripper.lex(line)
        highlighted = if tokens.map { |token| token[2] }.join == line
          tokens.map do |_, kind, text, _|
            color = case kind
            when :on_kw then 35
            when :on_const then 36
            when :on_tstring_content, :on_tstring_beg, :on_tstring_end then 32
            when :on_int, :on_float, :on_symbeg then 33
            when :on_comment then 2
            else 1
            end
            style(clean(text.chomp("\n")), color)
          end.join
        else
          style(clean(line.chomp("\n")), 1)
        end
        @output.puts("  #{style(gutter, 2)}#{highlighted}")
      end
    end

    def result(result)
      say(result["output"]) unless result["output"].to_s.empty?
      clear_progress
      if result["status"] == "ok"
        @output.puts("\n  #{style('→', 36, 1)} #{clean(result.dig('result', 'value'))}\n\n")
      else
        @output.puts("\n  #{style('Error', 31, 1)}")
        say("#{result['error']}\n#{result['outcome']}")
      end
    end

    def style(text, *codes, stream: @output)
      return text unless stream.tty? && !ENV.key?("NO_COLOR")
      "\e[#{codes.join(';')}m#{text}\e[0m"
    end

    private

    def masked_secret
      value = +""
      escape = nil
      @input.raw do
        loop do
          char = @input.getc
          return nil if char.nil? || char == "\x04"
          raise Interrupt if char == "\x03"
          return value if char == "\r" || char == "\n"
          # Ignore terminal escape sequences, including bracketed-paste markers.
          if escape
            if escape == :start && ["[", "O"].include?(char)
              escape = :sequence
            elsif escape == :start || char.match?(/[A-Za-z~]/)
              escape = nil
            end
            next
          end
          case char
          when "\e" then escape = :start
          when "\b", "\x7f"
            unless value.empty?
              value.chop!
              @output.print("\b \b")
            end
          when "\x15" # Ctrl-U clears the current entry.
            @output.print("\b \b" * value.length)
            value.clear
          else
            next unless char.match?(/\A[!-~]\z/) && value.bytesize < 4096
            value << char
            @output.print("●")
          end
          @output.flush
        end
      end
    end

    def clean(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
           .gsub(/[\x00-\x08\x0b-\x1f\x7f\u0080-\u009f\u202a-\u202e\u2066-\u2069]/) { |char| "\\u%04x" % char.ord }
    end
  end
end
