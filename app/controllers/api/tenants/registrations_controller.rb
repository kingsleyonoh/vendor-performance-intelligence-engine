# frozen_string_literal: true

module Api
  module Tenants
    # POST /api/tenants/register — PRD §5.1 + §8b + §11.
    #
    # Public endpoint (allowlisted by `Auth::ApiKeyAuthenticator`). Gated by
    # `SELF_REGISTRATION_ENABLED=true`; disabled on managed hosts. Rate-limited
    # 5/min/IP by Rack::Attack (`tenants/register/ip` throttle).
    #
    # Response: 201 Created with serialized tenant + raw `api_key` returned
    # ONCE. Only the SHA-256 hash + 12-char prefix are persisted.
    class RegistrationsController < ::Api::BaseController
      # Public endpoint — no Current.tenant requirement.
      skip_before_action :require_tenant!

      def create
        unless self_registration_enabled?
          return render_api_error(
            ::Errors::JsonApiError::FORBIDDEN,
            message: "Self-registration is disabled on this host."
          )
        end

        contract_result = ::Tenants::RegistrationContract.new.call(registration_params)
        if contract_result.failure?
          return render_validation_error_from_contract(contract_result)
        end

        key = ::Tenants::ApiKeyGenerator.generate

        tenant = Tenant.new(
          tenant_attributes(contract_result.to_h).merge(
            api_key_hash: key.api_key_hash,
            api_key_prefix: key.api_key_prefix,
            is_active: true
          )
        )

        unless tenant.save
          if slug_taken?(tenant)
            return render_api_error(
              ::Errors::JsonApiError::CONFLICT,
              message: "A tenant with that slug already exists."
            )
          end

          return render_validation_error_from_model(tenant)
        end

        # Auto-seed the default `Default v1` scoring_rule (PRD §4.6 + §4.7
        # + §13.1). Every tenant must have an active rule on first signal
        # ingest — without it, the composite scorer cannot run. Failure
        # here is logged but does not roll back the tenant: an operator
        # can re-run `bin/rails db:seed` to back-fill the rule.
        seed_default_scoring_rule_for(tenant)

        ::Audit::Recorder.record(
          actor: "public_registration",
          action: "tenant.create",
          entity_type: "Tenant",
          entity_id: tenant.id,
          tenant_id: tenant.id,
          after_state: { slug: tenant.slug }
        )

        render json: {
          tenant: TenantSerializer.new(tenant).serializable_hash,
          api_key: key.raw_key
        }, status: :created
      end

      private

      def registration_params
        # dry-validation expects a plain hash with symbol keys. Accept both
        # JSON-parsed (ActionController::Parameters) and raw-hash bodies.
        raw = request.request_parameters
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw.deep_symbolize_keys
      rescue StandardError
        {}
      end

      # Map validated params to the Tenant row. `name` is used as the
      # operational/internal name (PRD §4.1) and defaults to display_name
      # when not supplied — the API contract in §8b doesn't expose it.
      def tenant_attributes(params)
        {
          slug: params[:slug].to_s.strip.downcase,
          name: params[:display_name].to_s,
          legal_name: params[:legal_name].to_s,
          full_legal_name: params[:full_legal_name].to_s,
          display_name: params[:display_name].to_s,
          address: params[:address],
          registration: params[:registration],
          contact: params[:contact],
          wordmark_url: params[:wordmark_url],
          brand_primary_hex: params[:brand_primary_hex] || "#0D0D0F",
          brand_accent_hex: params[:brand_accent_hex] || "#3B82F6",
          locale: params[:locale] || "en-US",
          timezone: params[:timezone] || "UTC",
          settings: {}
        }.compact
      end

      def slug_taken?(tenant)
        tenant.errors.details[:slug].any? { |d| d[:error] == :taken }
      end

      def render_validation_error_from_contract(result)
        details = result.errors.to_h.flat_map do |path, issues|
          Array(issues).map { |issue| { path: path.to_s, issue: issue.to_s } }
        end
        render_api_error(
          ::Errors::JsonApiError::VALIDATION_ERROR,
          message: "Validation failed.",
          details: details
        )
      end

      def render_validation_error_from_model(record)
        details = record.errors.map { |err| { path: err.attribute.to_s, issue: err.message } }
        render_api_error(
          ::Errors::JsonApiError::VALIDATION_ERROR,
          message: "Validation failed.",
          details: details
        )
      end

      def self_registration_enabled?
        ENV.fetch("SELF_REGISTRATION_ENABLED", "true").to_s.downcase == "true"
      end

      # Pulls the canonical `db/seeds/scoring_rules.yml` template into a
      # `ScoringRule` row for the freshly-registered tenant. PRD §4.6 +
      # §13.1. Idempotent: re-runs no-op via `find_or_initialize_by`.
      def seed_default_scoring_rule_for(tenant)
        path = Rails.root.join("db", "seeds", "scoring_rules.yml")
        return unless File.exist?(path)

        template = YAML.load_file(path)
        return unless template.is_a?(Hash)

        rule = ScoringRule.find_or_initialize_by(tenant_id: tenant.id, name: template["name"])
        rule.assign_attributes(
          category_weights: template["category_weights"],
          signal_weight_overrides: template["signal_weight_overrides"] || {},
          band_thresholds: template["band_thresholds"],
          window_days: template["window_days"],
          time_decay_half_life_days: template["time_decay_half_life_days"],
          is_active: template["is_active"]
        )
        rule.save!
      rescue StandardError => e
        Rails.logger.error(
          "[registrations_controller] default scoring_rule seed failed for " \
          "tenant=#{tenant.id}: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
