# frozen_string_literal: true

# User — Rails 8 built-in auth model retrofitted with tenant_id in Batch
# 006 (security-audit H1). UI login flow (SessionsController) resolves
# Current.tenant from user.tenant on every authenticated request.
class User < ApplicationRecord
  has_secure_password
  belongs_to :tenant
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address,
            presence: true,
            uniqueness: { scope: :tenant_id, case_sensitive: false }
end
