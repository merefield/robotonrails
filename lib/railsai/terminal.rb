# frozen_string_literal: true
require "io/console"

module RailsAI
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
      @output.puts(clean(text))
    end

    def status(text)
      @error.puts(clean(text))
    end

    def prompt(label = "you> ")
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
          traffic_light(assessment, detail: "#{assessment.summary || 'local assessment'} · #{disposition}")
          unless automatic
            explanation = risk.explain_review
            say("Why review (LLM): #{explanation}") if explanation
          end
          say("#{environment} · #{args.fetch('purpose')}")
          args.fetch("code").each_line.with_index(1) { |line, index| say("%3d │ %s" % [index, line.chomp]) }
        else
          details = args.empty? ? "" : " #{JSON.generate(args)}"
          traffic_light(assessment, detail: "#{name}#{details} · #{disposition}")
        end
        return args if automatic
        return nil unless @input.tty?
        choice = nil
        loop do
          choice = prompt(name == "execute_ruby" ? "Execute? [y/e/d/N] (d: risk details): " : "Inspect? [y/N]: ")
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
      color = { green: 32, amber: 33, red: 31 }.fetch(assessment.level)
      label = clean("● #{assessment.level.to_s.upcase} · #{detail}").gsub("\n", " ")
      if @output.tty? && !ENV.key?("NO_COLOR")
        @output.puts("\e[#{color}m#{label}\e[0m")
      else
        say(label)
      end
    end

    def result(result)
      say(result["output"]) unless result["output"].to_s.empty?
      if result["status"] == "ok"
        say("=> #{result.dig('result', 'value')}")
      else
        say("#{result['error']}\n#{result['outcome']}")
      end
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
