# frozen_string_literal: true
# Evidence-only evaluation fixtures. Candidate methods and scopes are never run.
module ContractExamples
  class Filtered < Widget
    default_scope { where(name: "visible") }
  end

  class MutatingCount < Widget
    def self.count
      Widget.delete_all
    end
  end

  class UnknownCount < Widget
    def self.count
      UnresolvedService.compute
    end
  end
end
