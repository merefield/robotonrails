# frozen_string_literal: true
require "digest"

module RobotOnRails
  class Discovery
    attr_reader :roots

    def initialize(root)
      @root = File.realpath(root)
      @roots = [{ "id" => "app", "path" => @root }]
      @plugins = discover_plugins
      @source = SourceIndex.new(@roots)
    end

    def call(name, args)
      case name
      when "inventory" then inventory
      when "models" then { "models" => models.select { |m| m.name.downcase.include?(args.fetch("query").downcase) }.map(&:name).first(500) }
      when "describe_model" then describe_model(args.fetch("name"))
      when "read_source" then @source.read(**args.transform_keys(&:to_sym))
      when "search_source" then @source.search(**args.transform_keys(&:to_sym))
      else raise Error, "Unknown inspection tool."
      end
    end

    def inventory
      lock = File.join(@root, "Gemfile.lock")
      { "application" => Rails.application.class.name, "root" => @root,
        "environment" => Rails.env.to_s, "ruby" => RUBY_VERSION, "rails" => Rails.version,
        "dependency_fingerprint" => File.file?(lock) ? Digest::SHA256.file(lock).hexdigest : nil,
        "plugins" => @plugins, "source_roots" => roots,
        "note" => "Loaded runtime snapshot. Restart after deployments. Source files are read from disk on demand." }
    end

    private

    def discover_plugins
      entries = []
      if defined?(Rails::Engine)
        Rails::Engine.subclasses.each do |engine|
          next if engine == Rails.application.class
          path = engine.root.to_s
          next unless File.directory?(path)
          id = add_root(path)
          entries << { "name" => engine.name, "kind" => "rails_engine", "loaded" => true, "source_root" => id }
        end
      end
      if defined?(Discourse) && Discourse.respond_to?(:plugins)
        Discourse.plugins.each do |plugin|
          path = plugin.path.to_s
          path = File.dirname(path) unless File.directory?(path)
          next unless File.directory?(path)
          id = add_root(path)
          entries << { "name" => plugin.metadata.name.to_s, "kind" => "discourse_plugin", "loaded" => true, "source_root" => id }
        end
      end
      Dir.glob(File.join(@root, "plugins", "*", "plugin.rb")).sort.each do |file|
        path = File.realpath(File.dirname(file))
        next if @roots.any? { |r| r["path"] == path }
        entries << { "name" => File.basename(File.dirname(file)), "kind" => "plugin_directory", "loaded" => false, "source_root" => add_root(path) }
      end
      entries
    end

    def add_root(path)
      path = File.realpath(path)
      existing = @roots.find { |r| r["path"] == path }
      return existing["id"] if existing
      id = "source_#{@roots.length}"
      @roots << { "id" => id, "path" => path }
      id
    end

    def models
      return [] unless defined?(ActiveRecord::Base)
      ActiveRecord::Base.descendants.select { |model| model.name && !model.abstract_class? }.sort_by(&:name)
    end

    def describe_model(name)
      model = models.find { |candidate| candidate.name == name }
      raise Error, "Unknown loaded model: #{name}" unless model
      { "name" => name, "table" => model.table_name,
        "columns" => model.columns.map { |c| { "name" => c.name, "type" => c.type.to_s, "null" => c.null } },
        "associations" => model.reflect_on_all_associations.map { |a| { "name" => a.name.to_s, "kind" => a.macro.to_s, "class" => a.class_name } },
        "ancestors" => model.ancestors.filter_map(&:name).first(50),
        "methods" => model.instance_methods(false).sort.first(100).to_h { |method| [method.to_s, model.instance_method(method).source_location] } }
    end
  end
end
