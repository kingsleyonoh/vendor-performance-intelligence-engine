# frozen_string_literal: true

module Api
  # CRUD + activate + preview for /api/scoring_rules — PRD §4.6, §5, §8b.
  #
  # Lifecycle: operator creates a draft (is_active=false), tunes via
  # update, previews the band impact via POST /preview (PRD §15 #7 —
  # 10-vendor sample, NO persistence), then activates via POST /activate
  # (atomically deactivates the previously-active rule).
  #
  # The active rule cannot be deleted. Update of an active rule is
  # permitted (operator's current tuning) and is audit-logged.
  #
  # Tenant isolation: every action scopes via `tenant_scope` →
  # cross-tenant access → 404 (via ActiveRecord::RecordNotFound).
  class ScoringRulesController < ::Api::BaseController
    DEFAULT_PER_PAGE = 20
    MAX_PER_PAGE     = 100

    # Activation hooks — class-attribute array of procs invoked with the
    # newly-activated rule. Phase 3 wires AllVendorsRescoreJob here. Phase 1
    # default: no-op (rescore-all is a Phase 3 deliverable per docs/progress.md).
    class << self
      def on_activation_hooks
        @on_activation_hooks ||= []
      end
    end

    before_action :load_rule, only: %i[show update destroy activate preview]

    # ----------------------------------------------------------------
    # Index
    # ----------------------------------------------------------------

    def index
      authorize! ScoringRule, with: ScoringRulePolicy
      scope = tenant_scope

      page, per_page = pagination_params
      total = scope.count
      paged = scope.order(is_active: :desc, created_at: :desc)
                    .offset((page - 1) * per_page).limit(per_page)

      render json: {
        scoring_rules: ScoringRuleSerializer.new(paged).serializable_hash,
        pagination: {
          page: page, per_page: per_page,
          total_count: total, total_pages: (total.to_f / per_page).ceil
        }
      }, status: :ok
    end

    # ----------------------------------------------------------------
    # Show
    # ----------------------------------------------------------------

    def show
      authorize! @rule, with: ScoringRulePolicy
      render json: { scoring_rule: ScoringRuleSerializer.new(@rule).serializable_hash },
             status: :ok
    end

    # ----------------------------------------------------------------
    # Create
    # ----------------------------------------------------------------

    def create
      authorize! ScoringRule, with: ScoringRulePolicy

      body = request_body
      result = ::Scoring::RulesContract.new.call(body)
      if result.failure?
        return render_validation(result)
      end

      attrs = result.to_h.merge(tenant: Current.tenant, is_active: false)
      rule = ScoringRule.new(attrs)
      if rule.save
        render json: { scoring_rule: ScoringRuleSerializer.new(rule).serializable_hash },
               status: :created
      else
        render_model_validation_error(rule)
      end
    end

    # ----------------------------------------------------------------
    # Update
    # ----------------------------------------------------------------

    def update
      authorize! @rule, with: ScoringRulePolicy
      body = request_body

      # Partial updates: merge current rule attrs so the contract sees
      # the full shape. This matches PRD §8b — PATCH is a partial update.
      merged = current_rule_attrs.merge(body.slice(*allowed_update_keys))
      result = ::Scoring::RulesContract.new.call(merged)
      if result.failure?
        return render_validation(result)
      end

      if @rule.update(body.slice(*allowed_update_keys))
        render json: { scoring_rule: ScoringRuleSerializer.new(@rule).serializable_hash },
               status: :ok
      else
        render_model_validation_error(@rule)
      end
    end

    # ----------------------------------------------------------------
    # Destroy
    # ----------------------------------------------------------------

    def destroy
      authorize! @rule, with: ScoringRulePolicy
      if @rule.is_active?
        return render_api_error(
          ::Errors::JsonApiError::CONFLICT,
          message: "Cannot delete active rule. Activate another rule first."
        )
      end

      @rule.destroy!
      render json: { scoring_rule: ScoringRuleSerializer.new(@rule).serializable_hash },
             status: :ok
    end

    # ----------------------------------------------------------------
    # Activate — atomic flip
    # ----------------------------------------------------------------

    def activate
      authorize! @rule, to: :activate?, with: ScoringRulePolicy
      @rule.update!(is_active: true) unless @rule.is_active?

      Rails.logger.tagged("scoring") do
        Rails.logger.info(
          "scoring_rule.activated tenant=#{Current.tenant.id} rule=#{@rule.id} " \
            "name=#{@rule.name.inspect} — rescore all vendors pending (Phase 3)"
        )
      end

      self.class.on_activation_hooks.each do |hook|
        hook.call(@rule)
      rescue StandardError => e
        Rails.logger.error("[scoring_rules] activation hook failed: #{e.class}: #{e.message}")
      end

      render json: { scoring_rule: ScoringRuleSerializer.new(@rule).serializable_hash },
             status: :ok
    end

    # ----------------------------------------------------------------
    # Preview — PRD §15 #7. Dry-run the candidate rule against a sample of
    # 10 vendors and return band-change deltas. No vendor_scores rows are
    # persisted.
    # ----------------------------------------------------------------

    def preview
      authorize! @rule, to: :preview?, with: ScoringRulePolicy

      body = request_body
      sample_vendor_ids = Array(body[:vendor_ids] || body["vendor_ids"])
      sample_vendor_ids = sample_vendor_ids.select { |id| id.is_a?(String) }

      vendors =
        if sample_vendor_ids.any?
          Vendor.where(tenant_id: Current.tenant.id, id: sample_vendor_ids).to_a
        else
          sample_for_preview
        end

      previews = vendors.map { |v| preview_for_vendor(v) }.compact
      changed = previews.count { |p| %w[improving degrading crossed_up crossed_down].include?(p[:band_change].to_s) }

      render json: {
        previews: previews,
        summary: {
          total_previewed: previews.size,
          changed_count: changed,
          rule_id: @rule.id
        }
      }, status: :ok
    end

    # ==================================================================
    #                           private
    # ==================================================================

    private

    def tenant_scope
      ScoringRule.where(tenant_id: Current.tenant.id)
    end

    def load_rule
      @rule = tenant_scope.find(params[:id])
    end

    def allowed_update_keys
      %i[name category_weights signal_weight_overrides band_thresholds
         window_days time_decay_half_life_days]
    end

    def current_rule_attrs
      {
        name: @rule.name,
        category_weights: @rule.category_weights,
        signal_weight_overrides: @rule.signal_weight_overrides || {},
        band_thresholds: @rule.band_thresholds,
        window_days: @rule.window_days,
        time_decay_half_life_days: @rule.time_decay_half_life_days
      }
    end

    def render_validation(result)
      render_api_error(
        ::Errors::JsonApiError::VALIDATION_ERROR,
        message: "Validation failed.",
        details: ::Scoring::RulesContract.details_for(result)
      )
    end

    def render_model_validation_error(record)
      details = record.errors.map { |err| { path: err.attribute.to_s, issue: err.message } }
      render_api_error(
        ::Errors::JsonApiError::VALIDATION_ERROR,
        message: "Validation failed.",
        details: details
      )
    end

    # Sample picker for the preview endpoint. Returns up to 10 vendors —
    # those with the highest current composite_score (vendors most likely
    # to change band under a new rule). Falls back to the most recently
    # created vendors if no scores exist yet.
    def sample_for_preview
      sample_size = 10
      ranked_ids = VendorScore
                     .where(tenant_id: Current.tenant.id)
                     .select("DISTINCT ON (vendor_id) vendor_id, composite_score")
                     .order("vendor_id, computed_at DESC")
                     .map(&:vendor_id)

      # Now rank those vendor_ids by score
      scored = VendorScore
                 .where(tenant_id: Current.tenant.id, vendor_id: ranked_ids)
                 .order(composite_score: :desc)
                 .pluck(:vendor_id).uniq.first(sample_size)

      vendors = Vendor.where(tenant_id: Current.tenant.id, id: scored).to_a
      return vendors if vendors.size >= sample_size

      # Backfill from most recently created vendors to reach sample_size.
      needed = sample_size - vendors.size
      existing_ids = vendors.map(&:id)
      backfill = Vendor.where(tenant_id: Current.tenant.id)
                       .where.not(id: existing_ids)
                       .order(created_at: :desc)
                       .limit(needed)
                       .to_a
      vendors + backfill
    end

    # Preview a single vendor under the candidate rule without writing a
    # vendor_scores row. Returns nil if the vendor has no signals in
    # window (no preview to report).
    def preview_for_vendor(vendor)
      current = VendorScore.where(tenant_id: Current.tenant.id, vendor_id: vendor.id)
                           .order(computed_at: :desc).first

      result = ::Scoring::CompositeScorer.call(
        vendor_id: vendor.id, tenant: Current.tenant,
        scoring_rule: @rule, persist: false
      )
      return nil if result.nil?

      new_band = result[:band]
      new_composite = result[:composite_score]
      current_band = current&.band
      current_composite = current&.composite_score&.to_f
      {
        vendor_id: vendor.id,
        vendor_name: vendor.canonical_name,
        current_band: current_band,
        new_band: new_band,
        current_composite: current_composite,
        new_composite: new_composite,
        band_change: classify_band_change(current_band, new_band, current_composite, new_composite)
      }
    end

    def classify_band_change(current_band, new_band, current_composite, new_composite)
      return "new" if current_band.nil?
      return "stable" if current_band == new_band && (current_composite.to_f - new_composite.to_f).abs < 5

      current_idx = VendorScore::BANDS.index(current_band.to_s)
      new_idx = VendorScore::BANDS.index(new_band.to_s)
      return "stable" if current_idx.nil? || new_idx.nil? || current_idx == new_idx

      new_idx > current_idx ? "crossed_up" : "crossed_down"
    end

    def request_body
      raw = request.request_parameters
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      inner = raw["scoring_rule"] || raw[:scoring_rule] || raw
      inner.deep_symbolize_keys
    rescue StandardError
      {}
    end

    def pagination_params
      page = [params[:page].to_i, 1].max
      per_page = params[:per_page].present? ? params[:per_page].to_i : DEFAULT_PER_PAGE
      per_page = DEFAULT_PER_PAGE if per_page <= 0
      per_page = [per_page, MAX_PER_PAGE].min
      [page, per_page]
    end
  end
end
