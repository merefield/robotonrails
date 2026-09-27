# frozen_string_literal: true
require_relative "test_helper"

class WorkerTest < Minitest::Test
  def setup
    @config = RobotOnRails::Config.new({}, load_saved: false)
    @config.root = File.expand_path("fixtures/app", __dir__)
    @config.environment = "test"
    @config.boot_timeout = 30
    @worker = RobotOnRails::WorkerClient.new(@config).start
  end

  def teardown
    @worker&.stop
  end

  def execute(code)
    @worker.call("execute_ruby", { "code" => code, "purpose" => "test" })
  end

  def test_real_rails_boot_discovery_schema_and_plugin_source
    assert_equal "test", @worker.inventory["environment"]
    plugin = @worker.inventory["plugins"].find { |p| p["name"] == "demo" }
    assert plugin["loaded"]
    assert_equal "discourse_plugin", plugin["kind"]
    models = @worker.call("models", { "query" => "widget" })
    assert_includes models.dig("result", "models"), "Widget"
    model = @worker.call("describe_model", { "name" => "Widget" })
    assert_includes model.dig("result", "ancestors"), "DemoPlugin::WidgetExtension"
    assert model.dig("result", "columns").any? { |c| c["name"] == "name" }
    source = @worker.call("search_source", { "query" => "Hello from demo", "root" => plugin["source_root"] })
    assert_equal "plugin.rb", source.dig("result", "matches", 0, "path")
  end

  def test_persistent_variables_real_database_and_output
    assert_equal "ok", execute('chosen = Widget.create!(name: "First")')["status"]
    result = execute('puts "hello"; STDERR.puts "warning"; chosen.reload.name')
    assert_equal '"First"', result.dig("result", "value")
    assert_includes result["output"], "hello"
    assert_includes result["output"], "warning"
    assert_equal "1", execute("Widget.count").dig("result", "value")
  end

  def test_user_variables_do_not_overwrite_dispatch_state
    result = execute('discovery = nil; protocol = nil; args = nil; name = nil; "ok"')
    assert_equal "ok", result["status"]
    assert_equal "ok", @worker.call("inventory", {})["status"]
    assert_equal "42", execute("42").dig("result", "value")
  end

  def test_error_does_not_hide_partial_changes
    result = execute('Widget.create!(name: "Written"); raise "oops"')
    assert_equal "error", result["status"]
    assert_match(/may have occurred/, result["outcome"])
    assert_equal "1", execute("Widget.count").dig("result", "value")
  end

  def test_output_flood_is_bounded_without_deadlock
    result = execute('STDOUT.write("x" * 1_000_000); 42')
    assert_equal "ok", result["status"]
    assert_operator result["output"].bytesize, :<, 17_000
    assert_includes result["output"], "truncated"
  end

  def test_timeout_stops_worker_and_requires_explicit_restart
    @config.timeout = 0.05
    error = assert_raises(RobotOnRails::WorkerError) { execute("sleep 5") }
    assert_match(/outcome may be unknown/, error.message)
    assert_raises(RobotOnRails::WorkerError) { execute("42") }
    @config.timeout = 5
    @worker.start
    assert_equal "42", execute("42").dig("result", "value")
  end

  def test_process_exit_does_not_exit_client
    assert_raises(RobotOnRails::WorkerError) { execute("exit! 7") }
    @worker.start
    assert_equal "42", execute("42").dig("result", "value")
  end

  def test_runtime_evidence_reports_framework_count_without_executing_it
    evidence = @worker.call("risk_evidence", { "code" => "Widget.count" }).fetch("result")
    assert_equal "observed", evidence["status"]
    call = evidence.fetch("calls").first
    assert_equal "Widget", call["receiver"]
    assert_equal "count", call["method"]
    assert_equal "gem:activerecord", call.fetch("chain").first["origin"]
    assert call.fetch("chain").first.fetch("source_excerpt").include?("delegate")
    assert call.fetch("active_record_context").fetch("relation_methods").fetch("count").any?
  end

  def test_runtime_evidence_detects_overrides_and_refreshes_after_changes
    execute('class << Widget; def count; raise "must not execute"; end; end')
    evidence = @worker.call("risk_evidence", { "code" => "Widget.count" }).fetch("result")
    chain = evidence.fetch("calls").first.fetch("chain")
    assert_equal "(robotonrails)", chain.first.fetch("source_location").first
    assert chain.drop(1).any? { |entry| entry["origin"] == "gem:activerecord" }
    assert_equal "ok", @worker.call("risk_evidence", { "code" => "Widget.count" })["status"]
  end

  def test_runtime_evidence_does_not_resolve_dynamic_calls_or_autoload
    execute('Object.autoload(:EvidenceTrap, "/nonexistent/evidence_trap.rb")')
    evidence = @worker.call("risk_evidence", { "code" => "EvidenceTrap.count; Widget.where(active: true).count" }).fetch("result")
    assert_equal "unresolved", evidence.fetch("calls").first["status"]
    assert evidence["calls"].any? { |call| call["method"] == "count" && call["status"] == "inferred" }
    assert_equal '"/nonexistent/evidence_trap.rb"', execute('Object.autoload?(:EvidenceTrap)').dig("result", "value")
    large = @worker.call("risk_evidence", { "code" => Array.new(40, "Widget.count").join("; ") }).fetch("result")
    assert large["truncated"]
    assert_operator JSON.generate(large).bytesize, :<, 32_000
  end

  def test_inferred_query_chain_and_overrides_without_execution
    code = "Widget.where.not(name: nil).group(:name).order(Arel.sql('COUNT(*) DESC')).limit(1).count"
    evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
    count = evidence.fetch("calls").find { |call| call["method"] == "count" }
    assert_equal "inferred", count["status"], evidence.inspect
    assert_equal "ActiveRecord::Calculations", count.fetch("chain").first["owner"]
    execute('Widget.send(:relation_delegate_class, ActiveRecord::Relation).class_eval { def count; raise "must not execute"; end }')
    evidence = @worker.call("risk_evidence", {"code" => "Widget.where(name: nil).count"}).fetch("result")
    assert_equal "(robotonrails)", evidence.fetch("calls").first.fetch("chain").first.fetch("source_location").first
    execute('class << Widget; def where(*); raise "must not execute"; end; end')
    evidence = @worker.call("risk_evidence", {"code" => "Widget.where(name: nil).count"}).fetch("result")
    assert_equal "unresolved", evidence.fetch("calls").first["status"]
    assert_equal "ok", @worker.call("risk_evidence", {"code" => "Widget.where(name: nil).count"})["status"]
  end

  def test_grouped_aggregate_results_and_straight_line_locals
    code = 'top = Widget.group(:name).count.first; top && { key: top[0], count: top[1] }'
    evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
    first = evidence.fetch("calls").find { |call| call["method"] == "first" }
    assert_equal "inferred", first["status"]
    assert_equal "Enumerable", first.fetch("chain").first["owner"]
    indexes = evidence.fetch("calls").select { |call| call["method"] == "[]" }
    assert_equal 2, indexes.length
    assert indexes.all? { |call| call["status"] == "inferred" && call.fetch("chain").first["owner"] == "Array" }
    evidence = @worker.call("risk_evidence", {"code" => 'Widget.group(:name).count.values.first'}).fetch("result")
    assert_equal "Array", evidence.fetch("calls").first.fetch("chain").first["owner"]
  end

  def test_local_inference_does_not_survive_reassignment_branch_or_requests
    ['top = Widget.group(:name).count.first; top = unknown; top[0]',
     'top = Widget.group(:name).count.first; if true; top = unknown; end; top[0]',
     'top[0]'].each do |code|
      evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
      index = evidence.fetch("calls").find { |call| call["method"] == "[]" }
      assert_equal "unresolved", index["status"], code
    end
  end

  def test_unsupported_aggregate_shapes_do_not_invent_result_types
    ['Widget.group(nil).count.first', 'Widget.group(:name).count.first(2).first'].each do |code|
      evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
      assert_equal "unresolved", evidence.fetch("calls").first["status"], code
    end
  end

  def test_aggregate_override_stops_result_inference
    execute('Widget.send(:relation_delegate_class, ActiveRecord::Relation).class_eval { def count; raise "must not execute"; end }')
    evidence = @worker.call("risk_evidence", {"code" => 'Widget.group(:name).count.first'}).fetch("result")
    assert_equal "unresolved", evidence.fetch("calls").first["status"]
    count = evidence.fetch("calls").find { |call| call["method"] == "count" }
    assert_equal "(robotonrails)", count.fetch("chain").first.fetch("source_location").first
  end

  def test_pick_includes_model_specific_pluck_without_execution
    ['Widget.pick(:name)', 'Widget.where.not(name: nil).group(:name).limit(1).pick(:name)'].each do |code|
      evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
      pick = evidence.fetch("calls").find { |call| call["method"] == "pick" }
      pluck = pick.fetch("delegation_context").fetch("relation_methods").fetch("pluck").first
      assert_equal "ActiveRecord::Calculations", pluck["owner"]
      assert_includes pluck["source_excerpt"], "def pluck"
    end
    execute('Widget.send(:relation_delegate_class, ActiveRecord::Relation).class_eval { def pluck(*); raise "must not execute"; end }')
    ['Widget.pick(:name)', 'Widget.where(name: nil).pick(:name)'].each do |code|
      evidence = @worker.call("risk_evidence", {"code" => code}).fetch("result")
      pluck = evidence.fetch("calls").first.fetch("delegation_context").fetch("relation_methods").fetch("pluck")
      assert_equal "(robotonrails)", pluck.first.fetch("source_location").first
      assert pluck.drop(1).any? { |entry| entry["owner"] == "ActiveRecord::Calculations" }
    end
  end

  def evidence_for(code = "Widget.count")
    response = @worker.call("risk_evidence", { "code" => code })
    assert_equal "ok", response["status"], response.inspect
    response.fetch("result").fetch("calls").first.fetch("active_record_context")
  end

  def test_empty_registered_and_current_scope_metadata
    context = evidence_for
    scopes = context.fetch("registered_scopes")
    assert_equal "verified_value_reader", scopes["reader_status"]
    assert_equal 0, scopes["count"]
    assert_equal false, scopes["custom_default_scope_method"]
    assert_equal false, context.fetch("current_scope")["present"]
    refute context.fetch("model_methods").key?("default_scope")
    chain = context.fetch("relation_methods").fetch("count")
    assert_equal "resolved_method", chain.first["lookup_role"]
    assert_equal "super_method_available_not_observed_called", chain.last["lookup_role"]
  end

  def test_inherited_and_local_scopes_are_recorded_without_running_bodies
    result = execute('Widget.class_eval { default_scope { raise "scope body must not execute" } }; class ::ScopedWidget < ::Widget; default_scope(all_queries: true) { raise "second body must not execute" }; end')
    assert_equal "ok", result["status"]
    scopes = evidence_for("ScopedWidget.count").fetch("registered_scopes")
    assert_equal 2, scopes["count"]
    assert_equal [nil, true], scopes["entries"].map { |entry| entry["all_queries"] }
    assert scopes["entries"].all? { |entry| entry["body_executed"] == false && entry["kind"] == "proc" }
    assert scopes["entries"].all? { |entry| entry["source_location"].first == "(robotonrails)" }
  end

  def test_scope_block_source_is_reported_without_execution
    path = File.expand_path("fixtures/app/plugins/demo/scope_probe.rb", __dir__)
    assert_equal "ok", execute("require #{path.inspect}")["status"]
    entry = evidence_for("ScopeProbeWidget.count").fetch("registered_scopes").fetch("entries").first
    assert_includes %w[scope_source_lines scope_declaration_source], entry["source_extent"]
    assert_includes entry["source_excerpt"], "scope probe must not execute"
    assert_equal false, entry["body_executed"]
  end

  def test_custom_scope_reader_and_custom_default_scope_are_not_executed
    execute('def Widget.default_scopes; raise "reader must not execute"; end; def Widget.default_scope; raise "scope must not execute"; end')
    scopes = evidence_for.fetch("registered_scopes")
    assert_equal "unresolved_reader", scopes["reader_status"]
    refute scopes.key?("count")
    assert_equal true, scopes["custom_default_scope_method"]
    assert_equal "(robotonrails)", scopes["custom_default_scope_chain"].first["source_location"].first
  end

  def test_current_scope_registry_is_read_without_evaluating_relation
    execute('ActiveRecord::Scoping::ScopeRegistry.set_current_scope(Widget, Widget.unscoped.where(active: true))')
    context = evidence_for
    assert_equal true, context.fetch("current_scope")["present"]
    assert_equal "Widget", context.fetch("current_scope")["inherited_from"]
  end

  def test_environment_separates_provider_key
    assert_equal "nil", execute('ENV["OPENAI_API_KEY"]').dig("result", "value")
  end
end
