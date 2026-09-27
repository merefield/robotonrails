# frozen_string_literal: true
require_relative "test_helper"

class EvidenceQualityTest < Minitest::Test
  def fragment(source)
    lines = source.lines.map.with_index(1) { |line, n| "#{n}: #{line.chomp}" }
    RobotOnRails::MethodEvidence.allocate.send(:source_fragment, lines)
  end

  def test_missing_loaded_gem_directory_does_not_abort_evidence
    Dir.mktmpdir do |root|
      spec = Struct.new(:name, :full_gem_path).new("missing-bundler", File.join(root, "missing-bundler"))
      specs = Gem.loaded_specs.merge("missing-bundler" => spec)
      Gem.stub(:loaded_specs, specs) do
        evidence = RobotOnRails::MethodEvidence.new([{"path" => root}]).collect("String.new")
        assert_equal "observed", evidence["status"]
        assert_equal "observed", evidence.fetch("calls").first["status"]
        assert_includes evidence["unavailable_gem_sources"], {"name" => "missing-bundler", "reason" => "Errno::ENOENT"}
      end
    end
  end

  def test_generated_declaration_does_not_include_neighbouring_documentation
    result = fragment("delegate(*QUERYING_METHODS, to: :all)\n# Execute custom SQL\ndef find_by_sql(sql)\nend\n")
    assert_equal "declaration_only", result["source_extent"]
    refute_includes result["source_excerpt"], "custom SQL"
    refute_includes result["source_excerpt"], "find_by_sql"
  end

  def test_method_boundary_includes_nested_body_but_not_next_method
    result = fragment("def count\n  if true\n    'end'\n  end\nend\n# Unrelated\ndef destroy_all\nend\n")
    assert_equal "complete_method", result["source_extent"]
    assert_includes result["source_excerpt"], "5: end"
    refute_includes result["source_excerpt"], "Unrelated"
    refute_includes result["source_excerpt"], "destroy_all"
  end

  def test_truncation_is_explicit_and_endless_definition_is_complete
    assert_equal "truncated_method", fragment("def count\n  something\n")["source_extent"]
    assert_equal "complete_method", fragment("def count = 1\ndef another = 2\n")["source_extent"]
  end

  def test_factual_signals_ignore_warning_words_in_comments_and_strings
    risk = RobotOnRails::Risk.new
    facts = risk.factual_signals('User.count # destroy_all File')
    assert facts["parseable"]
    assert_empty facts["matched_method_names"]
    assert_empty facts["referenced_authority_constants"]
    refute facts.key?("level")
    facts = risk.factual_signals('File.write("system delete_all", "text")')
    assert_equal ["write"], facts["matched_method_names"]
    assert_equal ["File"], facts["referenced_authority_constants"]
    assert risk.factual_signals('system("echo hello")')["matched_method_names"].include?("system")
  end
end
