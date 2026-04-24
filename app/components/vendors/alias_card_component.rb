# frozen_string_literal: true

# Vendors::AliasCardComponent — shows all (source_system, source_ref) tuples
# pinned to this vendor, with confidence + confirm state. Pending aliases
# (is_confirmed=false) are surfaced first so operators can sweep them.
module Vendors
  class AliasCardComponent < ViewComponent::Base
    def initialize(aliases:)
      @aliases = Array(aliases)
    end

    attr_reader :aliases

    def empty?
      aliases.empty?
    end
  end
end
