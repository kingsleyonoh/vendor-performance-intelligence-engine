# frozen_string_literal: true

# Tenant — PRD §4.1 + §4.T. Root of the tenant-isolation invariant: every
# data-bearing table in the system hangs off this row. The §4.T identity
# columns (legal_name through timezone) are bound by every template
# surface (PDF, email, UI header, Hub payload) via
# `Tenants::CaptureSnapshot`.
class Tenant < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  HEX_COLOR = /\A#[0-9A-Fa-f]{6}\z/
  LOCALE_FORMAT = /\A[a-z]{2}-[A-Z]{2}\z/
  API_KEY_PREFIX_LENGTH = 12

  has_many :users, dependent: :restrict_with_exception
  has_many :sessions, dependent: :restrict_with_exception

  normalizes :slug, with: ->(v) { v.to_s.strip.downcase }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT, message: "must be lowercase alphanumeric with dashes" }
  validates :api_key_hash, presence: true, uniqueness: true, length: { is: 64 }
  validates :api_key_prefix, presence: true, uniqueness: true, length: { is: API_KEY_PREFIX_LENGTH }
  validates :legal_name, :full_legal_name, :display_name, presence: true
  validates :brand_primary_hex, :brand_accent_hex,
            format: { with: HEX_COLOR, message: "must be a #RRGGBB hex color" }
  validates :locale, format: { with: LOCALE_FORMAT, message: "must be BCP47 (e.g. en-US)" }
  validates :timezone, presence: true
end
