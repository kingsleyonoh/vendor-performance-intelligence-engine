# frozen_string_literal: true

# Vendors::FilterPanelComponent — PRD §5b. Renders the filter chips above
# the vendors list. Submitting the form reloads the Turbo Frame holding
# the table so the filters feel live without a full-page reload.
module Vendors
  class FilterPanelComponent < ViewComponent::Base
    BANDS = %w[low medium high critical].freeze

    def initialize(filters:, categories:)
      @filters = filters
      @categories = categories
    end

    attr_reader :filters, :categories
  end
end
