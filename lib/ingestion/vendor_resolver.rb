# frozen_string_literal: true

require "text"

module Ingestion
  # VendorResolver — PRD §5.2. Translates a `(tenant, source_system,
  # source_ref, hints)` tuple into a canonical `vendor_id`, creating or
  # reusing a `vendor_aliases` row for idempotency.
  #
  # Priority ladder:
  #
  #   1. Alias cache hit on `(tenant_id, source_system, source_ref)` — returns
  #      immediately. Provisional hits (is_confirmed=false) are logged via
  #      Audit::Recorder with the confidence value for operator review.
  #   2. Exact `tax_id` match within tenant — confidence 1.00, alias
  #      auto-confirmed (AUTO_CONFIRM_EXACT_TAXID=true, PRD §14 default).
  #   3. Exact `normalized_name` match within tenant — confidence 0.85, alias
  #      pending operator confirmation.
  #   4. Levenshtein distance <= AUTO_MATCH_FUZZY_THRESHOLD (default 2) over
  #      every active vendor's normalized_name — confidence 0.70, pending.
  #   5. No match — create fresh vendor, alias at confidence 1.00
  #      (trivially confirmed since the vendor was just minted).
  #
  # Each rung is a private method that returns the result hash on hit, or
  # `nil` on miss, so `.resolve` reads as a short orchestrator.
  #
  # See `.agent/knowledge/foundation/vendor-resolution-flow.md`.
  class VendorResolver
    # Return shape every caller reads:
    #   {
    #     vendor: Vendor,
    #     alias: VendorAlias,
    #     confidence: Float,  # 0.70 | 0.85 | 1.00
    #     was_created: Boolean
    #   }

    CONFIDENCE_EXACT_TAXID = 1.0
    CONFIDENCE_EXACT_NAME  = 0.85
    CONFIDENCE_FUZZY       = 0.70
    CONFIDENCE_NEW_VENDOR  = 1.0

    class << self
      def resolve(tenant:, source_system:, source_ref:, name: nil, tax_id: nil, country_code: nil)
        raise ArgumentError, "tenant is required" if tenant.nil?
        raise ArgumentError, "source_system is required" if source_system.to_s.empty?
        raise ArgumentError, "source_ref is required" if source_ref.to_s.empty?

        ActiveRecord::Base.transaction do
          existing = try_existing_alias(tenant, source_system, source_ref)
          return existing if existing

          normalized = normalize_if_present(name)
          ctx = {
            tenant: tenant, source_system: source_system, source_ref: source_ref,
            name: name, tax_id: tax_id, country_code: country_code, normalized: normalized
          }

          try_tax_id_match(ctx) ||
            try_normalized_name_match(ctx) ||
            try_fuzzy_match(ctx) ||
            create_new_vendor(ctx)
        end
      end

      private

      # Rung 1: idempotency — existing alias for the same triple.
      def try_existing_alias(tenant, source_system, source_ref)
        existing_alias = VendorAlias.where(
          tenant_id: tenant.id,
          source_system: source_system,
          source_ref: source_ref
        ).first
        return nil unless existing_alias

        record_provisional_match(tenant, existing_alias) unless existing_alias.is_confirmed
        {
          vendor: existing_alias.vendor,
          alias: existing_alias,
          confidence: existing_alias.confidence.to_f,
          was_created: false
        }
      end

      # Rung 2: tax_id exact match.
      def try_tax_id_match(ctx)
        return nil if ctx[:tax_id].blank?

        vendor = Vendor.where(tenant_id: ctx[:tenant].id, tax_id: ctx[:tax_id]).first
        return nil unless vendor

        build_result(
          tenant: ctx[:tenant], vendor: vendor,
          source_system: ctx[:source_system], source_ref: ctx[:source_ref],
          alias_text: ctx[:name], confidence: CONFIDENCE_EXACT_TAXID,
          is_confirmed: auto_confirm_exact_taxid?, was_created: false
        )
      end

      # Rung 3: exact normalized_name match.
      def try_normalized_name_match(ctx)
        return nil if ctx[:normalized].blank?

        vendor = Vendor.where(tenant_id: ctx[:tenant].id, normalized_name: ctx[:normalized]).first
        return nil unless vendor

        build_result(
          tenant: ctx[:tenant], vendor: vendor,
          source_system: ctx[:source_system], source_ref: ctx[:source_ref],
          alias_text: ctx[:name], confidence: CONFIDENCE_EXACT_NAME,
          is_confirmed: false, was_created: false
        )
      end

      # Rung 4: Levenshtein fuzzy match.
      def try_fuzzy_match(ctx)
        return nil if ctx[:normalized].blank?

        fuzzy_vendor = find_fuzzy_match(ctx[:tenant], ctx[:normalized])
        return nil unless fuzzy_vendor

        build_result(
          tenant: ctx[:tenant], vendor: fuzzy_vendor,
          source_system: ctx[:source_system], source_ref: ctx[:source_ref],
          alias_text: ctx[:name], confidence: CONFIDENCE_FUZZY,
          is_confirmed: false, was_created: false
        )
      end

      # Rung 5: create a new vendor + confirmed alias.
      def create_new_vendor(ctx)
        new_vendor = Vendor.create!(
          tenant: ctx[:tenant],
          canonical_name: ctx[:name].presence || ctx[:source_ref].to_s,
          tax_id: ctx[:tax_id].presence,
          country_code: ctx[:country_code].presence,
          status: "active"
        )

        build_result(
          tenant: ctx[:tenant], vendor: new_vendor,
          source_system: ctx[:source_system], source_ref: ctx[:source_ref],
          alias_text: ctx[:name], confidence: CONFIDENCE_NEW_VENDOR,
          is_confirmed: true, was_created: true
        )
      end

      def build_result(tenant:, vendor:, source_system:, source_ref:, alias_text:, confidence:, is_confirmed:, was_created:)
        new_alias = VendorAlias.create!(
          tenant: tenant,
          vendor: vendor,
          source_system: source_system,
          source_ref: source_ref,
          alias_text: alias_text,
          confidence: confidence,
          is_confirmed: is_confirmed
        )

        {
          vendor: vendor,
          alias: new_alias,
          confidence: confidence.to_f,
          was_created: was_created
        }
      end

      def normalize_if_present(name)
        return nil if name.to_s.strip.empty?

        Ingestion::NameNormalizer.call(name)
      rescue ArgumentError
        nil
      end

      def find_fuzzy_match(tenant, normalized_target)
        threshold = fuzzy_threshold
        return nil if normalized_target.to_s.empty?

        candidate = nil
        best_distance = threshold + 1

        Vendor.where(tenant_id: tenant.id).where.not(status: "terminated").find_each do |v|
          next if v.normalized_name.to_s.empty?

          distance = ::Text::Levenshtein.distance(v.normalized_name, normalized_target)
          if distance < best_distance
            best_distance = distance
            candidate = v
          end
        end

        best_distance <= threshold ? candidate : nil
      end

      def fuzzy_threshold
        ENV.fetch("AUTO_MATCH_FUZZY_THRESHOLD", "2").to_i
      end

      def auto_confirm_exact_taxid?
        ENV.fetch("AUTO_CONFIRM_EXACT_TAXID", "true").to_s.downcase == "true"
      end

      def record_provisional_match(tenant, existing_alias)
        return unless defined?(::Audit::Recorder)

        ::Audit::Recorder.record(
          actor: tenant,
          action: "vendor_resolver.provisional_match",
          entity_type: "VendorAlias",
          entity_id: existing_alias.id,
          tenant_id: tenant.id,
          after_state: { confidence: existing_alias.confidence.to_f }
        )
      rescue StandardError => e
        Rails.logger.warn("[vendor_resolver] audit failed: #{e.class}: #{e.message}")
      end
    end
  end
end
