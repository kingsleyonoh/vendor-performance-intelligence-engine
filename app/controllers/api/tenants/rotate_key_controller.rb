# frozen_string_literal: true

module Api
  module Tenants
    # POST /api/tenants/me/rotate-key — PRD §8b.
    #
    # Atomically rotates the caller's API key: a new raw key is generated,
    # the tenant row's `api_key_hash` + `api_key_prefix` are updated in a
    # single transaction, the TenantCache entry for the old prefix is
    # invalidated, and the raw new key is returned ONCE.
    #
    # Note: role-based gating of rotate-key is deferred per the batch design
    # decision (PRD §8b labels this "admin-tagged only" but the per-tenant
    # user-role model is not yet wired — today any holder of the current
    # API key is effectively the admin, since there is exactly one key per
    # tenant).
    class RotateKeyController < ::Api::BaseController
      def create
        old_prefix = Current.tenant.api_key_prefix
        key = ::Tenants::ApiKeyGenerator.generate

        Current.tenant.transaction do
          Current.tenant.update!(
            api_key_hash: key.api_key_hash,
            api_key_prefix: key.api_key_prefix
          )
        end

        # Invalidate cached prefix -> tenant mapping so the old key stops
        # resolving on the next request. The new prefix is lazily populated
        # on first authenticated hit.
        ::Cache::TenantCache.delete(old_prefix)

        ::Audit::Recorder.record(
          actor: Current.tenant,
          action: "tenant.rotate_key",
          entity_type: "Tenant",
          entity_id: Current.tenant.id,
          tenant_id: Current.tenant.id,
          before_state: { prefix: old_prefix },
          after_state: { prefix: key.api_key_prefix }
        )

        ::Analytics::Event.track(
          event: "api_key_rotated",
          tenant_id: Current.tenant.id,
          properties: { previous_prefix: old_prefix, new_prefix: key.api_key_prefix }
        )

        render json: { api_key: key.raw_key }, status: :ok
      end
    end
  end
end
