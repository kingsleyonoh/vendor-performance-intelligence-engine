# frozen_string_literal: true

# Retrofits tenant_id onto users + sessions. The Rails 8 auth generator
# created these tables in Batch 005 without tenant_id; that violated PRD
# §2 Architecture Principle 1 and surfaced as security-audit finding H1
# (HIGH). Fixed in Batch 006.
#
# Zero users exist in production-equivalent data at this point, so
# null: false works without a backfill step.
class AddTenantIdToUsersAndSessions < ActiveRecord::Migration[8.0]
  def change
    # users: drop the single-column email unique index, replace with
    # composite (tenant_id, email_address) unique index so the same
    # operator email can exist under multiple tenants (distinct logins).
    if index_exists?(:users, :email_address, name: "index_users_on_email_address")
      remove_index :users, name: "index_users_on_email_address"
    end
    add_reference :users, :tenant, type: :uuid, null: false, foreign_key: true, index: true
    add_index :users, [:tenant_id, :email_address], unique: true,
              name: "index_users_on_tenant_id_and_email_address"

    # sessions: defense-in-depth. Session rows carry tenant_id so an
    # authenticated UI request resolves Current.tenant in one hop with
    # no User#tenant_id join.
    add_reference :sessions, :tenant, type: :uuid, null: false, foreign_key: true, index: true
  end
end
