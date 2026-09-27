# frozen_string_literal: true
class ScopeProbeWidget < Widget
  default_scope { raise "scope probe must not execute" }
end
