# frozen_string_literal: true
module RobotOnRails
  module Tools
    # One provider-neutral contract, also validated before dispatch to the worker.
    DEFINITIONS = {
      "risk_evidence" => ["Internal runtime method provenance inspection.", { "code" => "string" }],
      "inventory" => ["Describe this Rails application, loaded engines and plugins, and source roots.", {}],
      "models" => ["List loaded ActiveRecord models, filtered by a case-insensitive substring.", { "query" => "string" }],
      "describe_model" => ["Inspect a loaded model's columns, associations and ancestors without reading records.", { "name" => "string" }],
      "search_source" => ["Search source literally. Use root IDs from inventory; empty root searches all roots. Results include file and line.", { "query" => "string", "root" => "string" }],
      "read_source" => ["Read up to 200 source lines from a root ID and relative path.", { "root" => "string", "path" => "string", "start_line" => "integer" }],
      "execute_ruby" => ["Propose Ruby to execute inside Rails. Review and automatic execution follow the configured risk policy. Give a specific purpose; never retry a failed mutation without checking its outcome.", { "code" => "string", "purpose" => "string" }]
    }.freeze

    def self.definitions(inspect_only: false, system_one: false)
      DEFINITIONS.filter_map do |name, (description, fields)|
        next if name == "risk_evidence"
        next if inspect_only && name == "execute_ruby"
        properties = fields.transform_values { |type| { type: type } }
        { name: name, description: description, parameters: {
          type: "object", properties: properties,
          required: properties.keys, additionalProperties: false
        } }
      end
    end

    def self.validate!(name, args)
      definition = DEFINITIONS[name] or raise Error, "Unknown tool: #{name}"
      fields = definition[1]
      raise Error, "Invalid arguments for #{name}." unless args.is_a?(Hash)
      keys = args.keys
      if name == "execute_ruby" && args.key?("risk")
        raise Error, "Invalid risk label." unless %w[green amber red].include?(args["risk"])
        keys = keys - ["risk"]
      end
      raise Error, "Invalid arguments for #{name}." unless keys.sort == fields.keys.sort
      fields.each do |key, type|
        expected = type == "integer" ? Integer : String
        raise Error, "Invalid #{key}." unless args[key].is_a?(expected)
        raise Error, "#{key} is too long." if args[key].is_a?(String) && args[key].bytesize > 16_384
      end
      raise Error, "start_line must be positive." if args.key?("start_line") && args["start_line"] < 1
      args
    end
  end
end
