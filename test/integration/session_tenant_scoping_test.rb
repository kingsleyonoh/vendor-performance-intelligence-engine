# frozen_string_literal: true

require "test_helper"

# Verifies that logging in via /session pins Current.tenant from the
# authenticated user's tenant. Addresses security-audit H1 (UI auth path
# must set Current.tenant parallel to the API middleware).
class SessionTenantScopingTest < ActionDispatch::IntegrationTest
  # Provide a test-only root route so `root_url` resolves during session
  # redirects. Real root-route definition lands in Phase 1 (UI dashboard).
  setup do
    Rails.application.routes.draw do
      resource :session
      resources :passwords, param: :token
      root to: ->(_env) { [200, {"content-type" => "text/plain"}, ["root"]] }
    end
  end

  teardown do
    Rails.application.reload_routes!
  end

  test "logging in as acme user pins session.tenant_id to acme" do
    post session_path, params: {
      email_address: "admin@example.com", password: "password123"
    }
    assert_response :redirect
    session_row = Session.last
    assert_not_nil session_row
    assert_equal users(:admin).tenant_id, session_row.tenant_id
    # Globex admin cannot collide with Acme admin even on same email —
    # validated separately in UserTest, but proven here via the distinct
    # tenant_id on the session row.
    assert_equal tenants(:acme_gmbh_de).id, session_row.tenant_id
  end

  test "logging in as globex user pins session.tenant_id to globex" do
    post session_path, params: {
      email_address: "operator@example.com", password: "password123"
    }
    assert_response :redirect
    session_row = Session.last
    assert_equal users(:operator).tenant_id, session_row.tenant_id
    assert_equal tenants(:globex_inc_us).id, session_row.tenant_id
  end
end
