# frozen_string_literal: true

require "test_helper"

# User is tenant-scoped — PRD §2 Architecture Principle 1. The Rails 8 auth
# generator initially created users without tenant_id; Batch 006 retrofits
# it in response to security-audit finding H1.
class UserTest < ActiveSupport::TestCase
  test "tenant_id is required" do
    user = User.new(email_address: "new@example.com", password: "password123")
    assert_not user.valid?
    assert_includes user.errors[:tenant], "must exist"
  end

  test "same email can exist under different tenants" do
    u1 = User.create!(
      tenant: tenants(:acme_gmbh_de),
      email_address: "shared@example.com",
      password: "password123"
    )
    u2 = User.new(
      tenant: tenants(:globex_inc_us),
      email_address: "shared@example.com",
      password: "password123"
    )
    assert u2.valid?, "same email under a different tenant must be valid"
    u2.save!
    assert_not_equal u1.id, u2.id
  end

  test "same email under same tenant is rejected (composite unique index)" do
    User.create!(
      tenant: tenants(:acme_gmbh_de),
      email_address: "dupe@example.com",
      password: "password123"
    )
    dup = User.new(
      tenant: tenants(:acme_gmbh_de),
      email_address: "dupe@example.com",
      password: "password123"
    )
    assert_not dup.valid?
    assert_includes dup.errors[:email_address], "has already been taken"
  end

  test "has_many sessions through the cascade" do
    user = users(:admin)
    assert_respond_to user, :sessions
  end

  test "session inherits tenant from user" do
    user = users(:admin)
    session = user.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")
    assert_equal user.tenant_id, session.tenant_id
  end
end
