# frozen_string_literal: true

# Layouts::TopNavComponent — PRD §5b, §8. Authenticated app chrome
# top bar. Binds to Current.tenant.display_name (live read — this surface
# is NOT snapshot-frozen, unlike alerts and PDFs).
module Layouts
  class TopNavComponent < ViewComponent::Base
    def initialize(tenant:, user:)
      @tenant = tenant
      @user = user
    end

    attr_reader :tenant, :user

    def tenant_display_name
      UiBrand.display_name_for(tenant)
    end
  end
end
