# frozen_string_literal: true
module DemoPlugin
  module WidgetExtension
    def greeting = "Hello from demo"
  end
end

# Small fixture implementing the public registry shape used by Discourse.
module Discourse
  def self.plugins
    metadata = Struct.new(:name).new("demo")
    [Struct.new(:path, :metadata).new(__FILE__, metadata)]
  end
end
