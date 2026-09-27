# frozen_string_literal: true
require "ripper"

module RailsAI
  # Reflection only: never evaluate the candidate, invoke its methods, or autoload constants.
  class MethodEvidence
    def initialize(roots)
      @roots = roots.map { |root| root.fetch("path") }
      @gem_roots = Gem.loaded_specs.values.to_h { |spec| [File.realpath(spec.full_gem_path), spec.name] }
      @source = SourceIndex.new((@roots + @gem_roots.keys).uniq.each_with_index.map { |path, i| { "id" => i.to_s, "path" => path } })
      @source_roots = (@roots + @gem_roots.keys).uniq
    end

    def collect(code)
      tree = Ripper.sexp(code)
      return { "status" => "unparsed", "calls" => [], "limitations" => ["Ruby could not be parsed."] } unless tree
      nodes = []
      @local_types = {}
      @node_locals = {}
      tree[1].each do |statement|
        statement_nodes = []
        walk(statement, statement_nodes)
        # Only straight-line, top-level simple assignments carry types forward.
        # Branches, blocks and nested assignments invalidate local provenance.
        simple_assignment = statement[0] == :assign && statement.dig(1, 0) == :var_field && statement.dig(1, 1, 0) == :@ident
        unsafe = contains_control_or_assignment?(simple_assignment ? statement[2] : statement)
        @local_types.clear if unsafe
        statement_nodes.each { |node| @node_locals[node.object_id] = @local_types.dup }
        nodes.concat(statement_nodes)
        if simple_assignment
          type = unsafe ? nil : infer_receiver(statement[2])
          @local_types[statement[1][1][1]] = type
        end
      end
      calls = []
      nodes.first(12).each do |node|
        @local_types = @node_locals.fetch(node.object_id, {})
        entry = inspect_call(node)
        break if JSON.generate(calls + [entry]).bytesize > 28_000
        calls << entry
      end
      { "status" => "observed", "calls" => calls, "truncated" => nodes.length > calls.length,
        "limitations" => [
          "Constant receivers are resolved directly. Supported ActiveRecord chains have conditional static receiver inference; other dynamic receivers remain unresolved. Inference does not execute arguments or prove effects.",
          "Source origin is not verification against pristine gem contents. Native and generated methods may lack readable source.",
          "Source entries state whether they contain a complete method, a declaration only, or a truncated excerpt. Downstream behavior, callbacks, scopes and database functions are not proven safe.",
          "No candidate Ruby or scope was executed. Observations are a current worker snapshot, not a security guarantee."
        ] }
    end

    private

    def walk(node, calls)
      return unless node.is_a?(Array)
      calls << node if %i[call command_call fcall vcall aref].include?(node[0])
      node.each { |child| walk(child, calls) if child.is_a?(Array) }
    end

    def contains_control_or_assignment?(node)
      return false unless node.is_a?(Array)
      return true if %i[assign opassign massign if unless if_mod unless_mod case while until for method_add_block def defs class module].include?(node[0])
      node.any? { |child| child.is_a?(Array) && contains_control_or_assignment?(child) }
    end

    def constant_name(node)
      return unless node.is_a?(Array)
      case node[0]
      when :var_ref, :const_ref, :top_const_ref
        node[1][1] if node[1][0] == :@const
      when :const_path_ref
        parent = constant_name(node[1])
        "#{parent}::#{node[2][1]}" if parent
      end
    end

    def resolve(name)
      name.split("::").inject(Object) do |scope, part|
        return nil unless scope.is_a?(Module)
        return nil if Module.instance_method(:autoload?).bind_call(scope, part)
        return nil unless Module.instance_method(:const_defined?).bind_call(scope, part, false)
        Module.instance_method(:const_get).bind_call(scope, part, false)
      end
    end

    def inspect_call(node)
      direct = %i[call command_call aref].include?(node[0])
      name = direct ? constant_name(node[1]) : nil
      method_name = node[0] == :aref ? "[]" : (direct ? node[3] : node[1])[1]
      entry = { "receiver" => name || "(dynamic or implicit)", "method" => method_name }
      receiver = name && resolve(name)
      unless receiver.is_a?(Module)
        inferred = direct && infer_receiver(node[1])
        return entry.merge("status" => "unresolved") unless inferred
        model, owner, kind = inferred
        entry.merge!("receiver" => "#{model.name} (#{kind})", "status" => "inferred",
          "resolution_role" => "Conditional static receiver-type inference from framework/native method provenance; nullable result types describe the non-nil branch only. Not executed or a safety judgment",
          "chain" => chain(owner, method_name))
        entry["delegation_context"] = pick_context(owner) if method_name == "pick" && kind == "relation"
        return entry
      end
      singleton = Object.instance_method(:singleton_class).bind_call(receiver)
      entry.merge!("status" => "observed", "resolution_role" => "Direct receiver method lookup; not an execution trace", "chain" => chain(singleton, method_name))
      if defined?(ActiveRecord::Base) && receiver.is_a?(Class) && receiver < ActiveRecord::Base
        relation = model_relation_class(receiver)
        entry["active_record_context"] = {
          "model_methods" => %w[all].to_h { |n| [n, chain(singleton, n)] },
          "relation_methods" => (method_name == "count" ? %w[count calculate] : [method_name]).to_h { |n| [n, chain(relation || ActiveRecord::Relation, n)] },
          "registered_scopes" => registered_scopes(receiver, singleton),
          "current_scope" => current_scope_metadata(receiver),
          "context_role" => "Contextual method resolution only; these methods have not been observed executing.",
          "scope_execution" => "No scope body or relation was executed. Scope metadata getters are read only when their bytecode is verified as a simple value reader."
        }
      end
      if method_name == "pick" && entry["active_record_context"]
        entry["delegation_context"] = relation ? pick_context(relation) : {
          "status" => "unavailable", "note" => "Loaded model-specific relation class unavailable; pick delegation not resolved." }
      end
      entry
    rescue NameError, TypeError
      entry.merge("status" => "unresolved")
    end

    def pick_context(owner)
      { "status" => "observed", "relation_class" => owner.name,
        "relation_methods" => { "pluck" => chain(owner, "pluck") },
        "context_role" => "Bounded contextual lookup for the framework pick-to-pluck path on the loaded model-specific relation class. Branch selection and delegation were not observed executing; custom pick implementations may follow other paths." }
    end

    def model_relation_class(model)
      cache = ivar(model, :@relation_delegate_cache)
      relation = Hash.instance_method(:[]).bind_call(cache, ActiveRecord::Relation) if cache.instance_of?(Hash)
      relation if relation.is_a?(Class) && relation < ActiveRecord::Relation
    end

    # Follow a deliberately small set of query-builder return types. Inspect loaded
    # model-specific relation classes, so plugin overrides remain visible. Never
    # instantiate a relation, invoke a query builder, or evaluate its arguments.
    def infer_receiver(node, depth = 0)
      return nil unless node.is_a?(Array) && depth < 12
      if node[0] == :var_ref && node.dig(1, 0) == :@ident
        return @local_types[node[1][1]]
      end
      name = constant_name(node)
      if name
        model = resolve(name)
        return [model, Object.instance_method(:singleton_class).bind_call(model), "model"] if
          defined?(ActiveRecord::Base) && model.is_a?(Class) && model < ActiveRecord::Base
        return nil
      end
      arguments = nil
      if node[0] == :method_add_arg
        arguments = node[2]
        node = node[1]
      end
      return nil unless %i[call aref].include?(node[0])
      prior = infer_receiver(node[1], depth + 1)
      return nil unless prior
      model, owner, kind, grouped = prior
      method_name = node[0] == :aref ? "[]" : node[3][1]
      method = Module.instance_method(:instance_method).bind_call(owner, method_name)
      if %w[count_hash pair_or_nil counts_array scalar_or_nil].include?(kind)
        return nil unless method.source_location.nil?
        return nil unless arguments.nil? || arguments == [:arg_paren, nil]
        if kind == "count_hash" && method_name == "first" && method.owner == Enumerable
          return [model, Array, "pair_or_nil"]
        elsif kind == "count_hash" && method_name == "values" && method.owner == Hash
          return [model, Array, "counts_array"]
        elsif kind == "counts_array" && method_name == "first" && method.owner == Array
          return [model, Integer, "scalar_or_nil"]
        end
        return nil
      end
      return nil unless %w[where not group order reorder limit offset select distinct joins left_joins includes references having count].include?(method_name)
      method = Module.instance_method(:instance_method).bind_call(owner, method_name)
      root = Gem.loaded_specs["activerecord"]&.full_gem_path
      return nil unless root && method.source_location&.first&.start_with?(root + "/")
      expected = if kind == "model"
        ActiveRecord::Querying
      elsif kind == "where_chain"
        ActiveRecord::QueryMethods::WhereChain
      elsif method_name == "count"
        ActiveRecord::Calculations
      else
        ActiveRecord::QueryMethods
      end
      return nil unless method.owner == expected
      if method_name == "count"
        return grouped ? [model, Hash, "count_hash"] : nil
      end
      return nil if method_name == "not" && kind != "where_chain"
      if method_name == "where" && (arguments.nil? || arguments == [:arg_paren, nil])
        return [model, ActiveRecord::QueryMethods::WhereChain, "where_chain", grouped]
      end
      cache = ivar(model, :@relation_delegate_cache)
      relation = Hash.instance_method(:[]).bind_call(cache, ActiveRecord::Relation) if cache.instance_of?(Hash)
      return nil unless relation.is_a?(Class) && relation < ActiveRecord::Relation
      [model, relation, "relation", grouped || (method_name == "group" && symbol_arguments?(arguments))]
    rescue NameError, TypeError
      nil
    end

    def symbol_arguments?(arguments)
      args = arguments&.dig(0) == :arg_paren ? arguments[1] : arguments
      args.is_a?(Array) && args[0] == :args_add_block && args[2] == false &&
        args[1].is_a?(Array) && !args[1].empty? && args[1].all? { |arg| arg[0] == :symbol_literal }
    end

    def ivar(object, name)
      Object.instance_method(:instance_variable_get).bind_call(object, name)
    end

    def instructions(method)
      return nil unless defined?(RubyVM::InstructionSequence)
      RubyVM::InstructionSequence.of(method)&.to_a&.last&.select { |item| item.is_a?(Array) }
    end

    # A class_attribute value is held in a closure in current Rails versions.
    # Do not trust a reader merely because its name or source path looks familiar.
    def scope_values(receiver, singleton)
      reader = Module.instance_method(:instance_method).bind_call(singleton, :default_scopes)
      ops = instructions(reader)
      if ops&.length == 3 && ops[0] == [:putself] && ops[2] == [:leave] &&
          ops[1][0] == :opt_send_without_block &&
          ops[1][1][:mid] == :__class_attr_default_scopes && ops[1][1][:orig_argc] == 0
        reader = Module.instance_method(:instance_method).bind_call(singleton, :__class_attr_default_scopes)
        ops = instructions(reader)
      end
      # Only load a captured local and return it: no sends, branches or assignments.
      return nil unless ops&.length == 2 && ops.last == [:leave] &&
        %i[getlocal getlocal_WC_0 getlocal_WC_1].include?(ops.first.first)
      value = reader.bind_call(receiver)
      value if value.instance_of?(Array)
    rescue NameError, TypeError
      nil
    end

    def registered_scopes(receiver, singleton)
      macro = Module.instance_method(:instance_method).bind_call(singleton, :default_scope)
      framework_root = Gem.loaded_specs["activerecord"]&.full_gem_path
      macro_path = macro.source_location&.first
      stock_macro = framework_root && macro_path && macro_path.start_with?(framework_root + "/") && macro.owner == ActiveRecord::Scoping::Default::ClassMethods &&
        macro == ActiveRecord::Scoping::Default::ClassMethods.instance_method(:default_scope)
      values = scope_values(receiver, singleton)
      result = { "reader_status" => values ? "verified_value_reader" : "unresolved_reader",
        "custom_default_scope_method" => !stock_macro,
        "default_scope_method_role" => stock_macro ? "Framework registration macro, not an executed scope body" : "Custom default_scope implementation; body not invoked" }
      result["custom_default_scope_chain"] = chain(singleton, :default_scope) unless stock_macro
      if values
        result["count"] = values.length
        result["entries"] = values.first(12).map do |record|
          unless record.instance_of?(ActiveRecord::Scoping::DefaultScope)
            next { "status" => "unknown_scope_record" }
          end
          callable = ivar(record, :@scope)
          all_queries = ivar(record, :@all_queries)
          entry = { "all_queries" => [true, false, nil].include?(all_queries) ? all_queries : "unknown",
            "body_executed" => false }
          if callable.is_a?(Proc)
            entry["kind"] = "proc"
            entry["source_location"] = Proc.instance_method(:source_location).bind_call(callable)
            entry.merge!(scope_source(callable, entry["source_location"]))
          else
            entry["kind"] = "callable_object"
            entry["call_chain"] = chain(Object.instance_method(:singleton_class).bind_call(callable), :call)
          end
          entry
        end
        result["truncated"] = values.length > 12
      end
      result
    rescue NameError, TypeError
      { "reader_status" => "unresolved", "body_executed" => false }
    end

    def scope_source(callable, location)
      path, line = location
      return { "source_extent" => "unavailable" } unless path && File.file?(path)
      real = File.realpath(path)
      root = @source_roots.find { |candidate| real.start_with?(candidate + "/") }
      return { "source_extent" => "outside_inspection_roots" } unless root
      source = @source.read(root: @source_roots.index(root).to_s, path: real.delete_prefix(root + "/"), start_line: line)
      ast = begin
        RubyVM::AbstractSyntaxTree.of(callable) if defined?(RubyVM::AbstractSyntaxTree)
      rescue ArgumentError, RuntimeError
        nil # Some Ruby compilers cannot expose an AST for already-loaded code.
      end
      if ast && ast.first_lineno == line
        length = ast.last_lineno - line + 1
        lines = source.fetch("lines").first(length)
        text = lines.join("\n")
        complete = lines.length == length && text.bytesize <= 6000
        { "source_excerpt" => text.byteslice(0, 6000).encode("UTF-8", invalid: :replace, undef: :replace),
          "source_extent" => complete ? "scope_source_lines" : "truncated_scope_source",
          "source_note" => "Lines containing the scope block, located from runtime AST; adjacent expressions on the same lines may also appear." }
      else
        lines = source.fetch("lines")
        selected = []
        complete = false
        lines.each do |line|
          break if selected.join("\n").bytesize + line.bytesize > 6000
          selected << line
          if Ripper.sexp(selected.map { |item| item.sub(/\A\d+: /, "") }.join("\n"))
            complete = true
            break
          end
        end
        { "source_excerpt" => selected.join("\n"),
          "source_extent" => complete ? "scope_declaration_source" : "truncated_scope_source",
          "source_note" => "Runtime block location with on-disk syntax boundary; may include the registration expression, not just its block." }
      end
    rescue Error, ArgumentError, RuntimeError, SystemCallError
      { "source_extent" => "unavailable" }
    end

    def current_scope_metadata(receiver)
      # Rails 8 storage layout verified against the installed framework.
      return { "status" => "unsupported_layout" } unless Gem.loaded_specs["activerecord"]&.version&.segments&.first == 8
      storage = ivar(ActiveSupport::IsolatedExecutionState, :@scope)
      context = storage == Thread ? Thread.current : storage == Fiber ? Fiber.current : nil
      return { "status" => "unknown_execution_context" } unless context
      state = ivar(context, :@active_support_execution_state)
      return { "status" => "observed", "present" => false, "default_scopes_ignored" => false } if state.nil?
      return { "status" => "unresolved_storage" } unless state.instance_of?(Hash)
      registry = Hash.instance_method(:fetch).bind_call(state, :active_record_scope_registry, nil)
      return { "status" => "observed", "present" => false, "default_scopes_ignored" => false } if registry.nil?
      return { "status" => "unresolved_registry" } unless registry.instance_of?(ActiveRecord::Scoping::ScopeRegistry)
      base = ivar(receiver, :@base_class)
      return { "status" => "unknown_model_hierarchy" } unless base.is_a?(Class)
      names = []
      klass = receiver
      while klass && klass <= ActiveRecord::Base
        names << Module.instance_method(:name).bind_call(klass)
        break if klass == base
        klass = Class.instance_method(:superclass).bind_call(klass)
      end
      scopes = ivar(registry, :@current_scope)
      ignored = ivar(registry, :@ignore_default_scope)
      return { "status" => "unresolved_registry" } unless scopes.instance_of?(Hash) && ignored.instance_of?(Hash)
      scope_name = names.find { |name| Hash.instance_method(:fetch).bind_call(scopes, name, nil) }
      { "status" => "observed", "present" => !scope_name.nil?, "inherited_from" => scope_name,
        "default_scopes_ignored" => names.any? { |name| Hash.instance_method(:fetch).bind_call(ignored, name, nil) },
        "note" => "Current execution-context snapshot; relation contents were not evaluated. Executor hooks or later code can change it." }
    rescue NameError, TypeError
      { "status" => "unresolved_registry" }
    end

    def source_fragment(lines)
      plain = lines.map { |line| line.sub(/\A\d+: /, "") }
      unless plain.first.to_s.match?(/\A\s*def\b/)
        return { "source_excerpt" => lines.first.to_s, "source_extent" => "declaration_only",
          "source_note" => "Generated method or non-def source location; only the declaration line is shown." }
      end
      selected = []
      complete = false
      plain.each_with_index do |line, index|
        break if selected.join("\n").bytesize + lines[index].bytesize > 6000
        selected << lines[index]
        if Ripper.sexp(plain.first(index + 1).join("\n"))
          complete = true
          break
        end
      end
      { "source_excerpt" => selected.join("\n"),
        "source_extent" => complete ? "complete_method" : "truncated_method",
        "source_note" => "Method boundary determined from on-disk Ruby syntax; disk source may differ from loaded code." }
    end

    def chain(owner, name)
      method = Module.instance_method(:instance_method).bind_call(owner, name)
      entries = []
      4.times do
        break unless method
        path, line = method.source_location
        origin = "native_or_unknown"
        real = File.realpath(path) if path && File.file?(path)
        if real
          gem_root = @gem_roots.keys.find { |root| real.start_with?(root + "/") }
          origin = gem_root ? "gem:#{@gem_roots[gem_root]}" : "application_plugin_or_other"
        end
        entry = { "lookup_role" => entries.empty? ? "resolved_method" : "super_method_available_not_observed_called", "owner" => method.owner.to_s, "source_location" => method.source_location, "origin" => origin }
        if real && line
          root = @source_roots.find { |candidate| real.start_with?(candidate + "/") }
          if root
            begin
              excerpt = @source.read(root: @source_roots.index(root).to_s, path: real.delete_prefix(root + "/"), start_line: line)
              entry.merge!(source_fragment(excerpt.fetch("lines")))
            rescue Error, KeyError
              entry["source_excerpt"] = "(unavailable)"
            end
          end
        end
        entries << entry
        method = method.super_method
      end
      entries
    rescue NameError
      []
    end
  end
end
