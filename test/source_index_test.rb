# frozen_string_literal: true
require_relative "test_helper"

class SourceIndexTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @outside = Dir.mktmpdir
    File.write(File.join(@dir, "model.rb"), "class Example\n  # unique-marker\nend\n")
    @index = RailsAI::SourceIndex.new([{ "id" => "app", "path" => @dir }])
  end
  def teardown
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@outside)
  end

  def test_source_has_provenance_and_line_numbers
    result = @index.read(root: "app", path: "model.rb", start_line: 2)
    assert_equal "2:   # unique-marker", result["lines"].first
    assert_equal Digest::SHA256.file(File.join(@dir, "model.rb")).hexdigest, result["sha256"]
    assert_equal 2, @index.search(query: "unique-marker", root: "")["matches"].first["line"]
  end

  def test_symlink_escape_is_blocked
    File.write(File.join(@outside, "secret.rb"), "private")
    File.symlink(File.join(@outside, "secret.rb"), File.join(@dir, "escape.rb"))
    assert_raises(RailsAI::Error) { @index.read(root: "app", path: "escape.rb", start_line: 1) }
    assert_empty @index.search(query: "private", root: "")["matches"]
  end

  def test_traversal_and_secret_files_are_blocked
    File.write(File.join(@outside, "outside.rb"), "secret")
    assert_raises(RailsAI::Error) { @index.read(root: "app", path: File.join(@outside, "outside.rb"), start_line: 1) }
    File.write(File.join(@dir, "credentials.yml"), "password: private")
    assert_raises(RailsAI::Error) { @index.read(root: "app", path: "credentials.yml", start_line: 1) }
    assert_empty @index.search(query: "private", root: "")["matches"]
  end

  def test_file_size_and_ranges_are_bounded
    File.write(File.join(@dir, "big.rb"), "x" * (RailsAI::SourceIndex::MAX_FILE_BYTES + 1))
    assert_raises(RailsAI::Error) { @index.read(root: "app", path: "big.rb", start_line: 1) }
    File.write(File.join(@dir, "lines.rb"), "line\n" * 500)
    assert_equal 200, @index.read(root: "app", path: "lines.rb", start_line: 1)["lines"].length
  end
end
