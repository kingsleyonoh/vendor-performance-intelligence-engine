# frozen_string_literal: true

# Layouts::SidebarComponent — PRD §5b, §8. Left-side navigation with
# current-page highlight. Some entries have sub-items (Settings) that
# expand under the parent when the parent's path prefix is active.
module Layouts
  class SidebarComponent < ViewComponent::Base
    NAV_ITEMS = [
      { label: "Dashboard", path: "/",         key: :dashboard },
      { label: "Vendors",   path: "/vendors",  key: :vendors },
      { label: "Alerts",    path: "/alerts",   key: :alerts },
      { label: "Aliases",   path: "#",         key: :aliases,  disabled: true },
      { label: "Reports",   path: "/reports",  key: :reports },
      {
        label: "Settings",  path: "/settings", key: :settings,
        children: [
          { label: "Ingestion Sources", path: "/settings/ingestion-sources",
            key: :"settings-ingestion-sources" }
        ]
      }
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
