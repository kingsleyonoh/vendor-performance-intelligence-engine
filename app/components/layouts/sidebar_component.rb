# frozen_string_literal: true

# Layouts::SidebarComponent — PRD §5b, §8. Left-side navigation with
# current-page highlight. Links stub out Phase 2/3 surfaces (Aliases,
# Reports, Settings) so the IA is visible from Phase 1 — clicks route
# to `#` placeholders until those pages land.
module Layouts
  class SidebarComponent < ViewComponent::Base
    NAV_ITEMS = [
      { label: "Dashboard", path: "/",         key: :dashboard },
      { label: "Vendors",   path: "/vendors",  key: :vendors },
      { label: "Alerts",    path: "/alerts",   key: :alerts },
      { label: "Aliases",   path: "#",         key: :aliases,  disabled: true },
      { label: "Reports",   path: "#",         key: :reports,  disabled: true },
      { label: "Settings",  path: "#",         key: :settings, disabled: true }
    ].freeze

    def initialize(current_path:)
      @current_path = current_path
    end

    def active?(item)
      path = item[:path]
      return false if path == "#"
      path == "/" ? @current_path == "/" : @current_path.start_with?(path)
    end

    def items
      NAV_ITEMS
    end
  end
end
