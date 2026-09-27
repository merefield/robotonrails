# frozen_string_literal: true
class Widget < ActiveRecord::Base
  include DemoPlugin::WidgetExtension
end
