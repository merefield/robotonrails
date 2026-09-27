# frozen_string_literal: true
require_relative "test_helper"

class PrivacyTest < Minitest::Test
  def test_redaction_of_known_secrets_and_nested_values
    redactor = RobotOnRails::Redactor.new({ "SYSTEM_ONE_KEY" => "a-secret-value" })
    value = redactor.call({ "result" => ["token is a-secret-value", "Bearer abcd1234"], "password" => "123" })
    assert_equal ["token is [REDACTED]", "Bearer [REDACTED]"], value["result"]
    assert_equal "[REDACTED]", value["password"]
  end

  def test_audit_is_private_and_contains_no_raw_code_or_results
    Dir.mktmpdir do |dir|
      path = File.join(dir, "audit.jsonl")
      audit = RobotOnRails::Audit.new(path)
      audit.record(name: "execute_ruby", arguments: { "code" => "secret_command" }, result: { "status" => "ok", "value" => "private result" })
      audit.close
      assert_equal 0o600, File.stat(path).mode & 0o777
      refute_match(/secret_command|private result/, File.read(path))
      assert_equal "ok", JSON.parse(File.read(path))["status"]
    end
  end
end
