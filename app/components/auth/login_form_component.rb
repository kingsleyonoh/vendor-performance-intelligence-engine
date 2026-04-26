# frozen_string_literal: true

# Auth::LoginFormComponent — PRD §5b, §8, §13.1. Renders the email +
# password form posted to `session_url`. Kept as a ViewComponent so the
# same form markup can be re-used by any future "confirm identity" or
# "re-authenticate" flows.
module Auth
  class LoginFormComponent < ViewComponent::Base
    def initialize(email: nil, alert: nil)
      @email = email
      @alert = alert
    end

    attr_reader :email, :alert
  end
end
