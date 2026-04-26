# frozen_string_literal: true

module Settings
  # Settings → API Keys UI controller — PRD §5b, §8, §13.3.
  #
  # HTML/Turbo surface for rotating the tenant API key. Mirrors
  # `Api::Tenants::RotateKeyController` (JSON). One key per tenant.
  #
  # Show: renders the current `api_key_prefix` only — the full raw key is
  # never persisted (only SHA-256 hash + 12-char prefix), so it can never
  # be recovered after rotation.
  #
  # Create (= rotate): generates a fresh key via Tenants::ApiKeyGenerator,
  # atomically updates the tenant row, invalidates the cached prefix
  # mapping, audits, and renders the new RAW key ONCE in the flash. The
  # operator must copy it before navigating away — subsequent visits show
  # only the new prefix.
  class ApiKeysController < ApplicationController
    def show
      @prefix = Current.tenant.api_key_prefix
      @new_raw_key = flash[:rotated_raw_key]
    end

    def create
      old_prefix = Current.tenant.api_key_prefix
      key = ::Tenants::ApiKeyGenerator.generate

      Current.tenant.transaction do
        Current.tenant.update!(
          api_key_hash: key.api_key_hash,
          api_key_prefix: key.api_key_prefix
        )
      end

      ::Cache::TenantCache.delete(old_prefix) if defined?(::Cache::TenantCache)

      ::Audit::Recorder.record(
        actor: Current.user || "tenant:#{Current.tenant.slug}",
        action: "tenant.rotate_key",
        entity_type: "Tenant",
        entity_id: Current.tenant.id,
        tenant_id: Current.tenant.id,
        before_state: { prefix: old_prefix },
        after_state:  { prefix: key.api_key_prefix }
      )

      flash[:rotated_raw_key] = key.raw_key
      flash[:notice] = "API key rotated. Copy the new key now — it will not be shown again."
      redirect_to settings_api_keys_path
    end
  end
end
