require "test_helper"

# Phase 0 / Batch 002 smoke test.
#
# Proves:
#   - Rails boots under RAILS_ENV=test
#   - The app module is `VPI` (from `rails new --name=vpi`)
#   - ActiveRecord connects to the vpi_test PostgreSQL database
#
# This test is replaced by real model tests as soon as Batch 003 lands
# the tenants + signal_definitions migrations, but it must keep passing.
class RailsSmokeTest < ActiveSupport::TestCase
  test "Rails boots and the application module name is VPI" do
    assert_equal "Vpi", Rails.application.class.module_parent_name
  end

  test "ActiveRecord is connected to the test database" do
    assert ActiveRecord::Base.connection.active?
    assert_equal "vpi_test", ActiveRecord::Base.connection_db_config.database
  end
end
