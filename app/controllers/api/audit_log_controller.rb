# frozen_string_literal: true

module Api
  # Audit Log JSON API — PRD §5, §8, §8b, §13.3.
  #
  # Endpoints (all tenant-scoped via Current.tenant from X-API-Key middleware):
  #
  #   GET /api/audit-log              — list with filters + pagination
  #   GET /api/audit-log/:id          — single audit row
  #
  # Rows are INSERT-only at the application layer (PRD §4.12) — there is
  # no create/update/destroy surface.
  #
  # "Admin-only" gate: per PRD §8 + Batch 007 design decision, the
  # API-key holder IS the admin (no per-user role in v1). Auth is
  # therefore enforced solely by `require_tenant!` in `Api::BaseController`
  # — missing/invalid X-API-Key → 401. Cross-tenant access → 404.
  class AuditLogController < ::Api::BaseController
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE     = 100

    before_action :load_entry, only: %i[show]

    # ---------------- INDEX ----------------
    def index
      authorize! AuditLogEntry, with: AuditLogEntryPolicy

      scope = tenant_scope
      scope = scope.where(entity_type: filter_params[:entity_type]) if filter_params[:entity_type].present?
      scope = scope.where(entity_id:   filter_params[:entity_id])   if filter_params[:entity_id].present?
      scope = scope.where(actor_type:  filter_params[:actor_type])  if filter_params[:actor_type].present?
      scope = scope.where(action:      filter_params[:action])      if filter_params[:action].present?
      scope = scope.where("occurred_at >= ?", parse_time(filter_params[:from])) if filter_params[:from].present?
      scope = scope.where("occurred_at <= ?", parse_time(filter_params[:to]))   if filter_params[:to].present?

      page, per_page = pagination_params
      total = scope.count
      paged = scope.order(occurred_at: :desc).offset((page - 1) * per_page).limit(per_page)

      render json: {
        entries: paged.map { |e| serialize(e) },
        pagination: {
          page: page,
          per_page: per_page,
          total_count: total,
          total_pages: (total.to_f / per_page).ceil
        }
      }, status: :ok
    end

    # ---------------- SHOW ----------------
    def show
      authorize! @entry, with: AuditLogEntryPolicy
      render json: { entry: serialize(@entry) }, status: :ok
    end

    private

    def tenant_scope
      AuditLogEntry.where(tenant_id: Current.tenant.id)
    end

    def load_entry
      @entry = tenant_scope.find(params[:id])
    end

    def serialize(entry)
      {
        id:           entry.id,
        tenant_id:    entry.tenant_id,
        actor_type:   entry.actor_type,
        actor_id:     entry.actor_id,
        action:       entry.action,
        entity_type:  entry.entity_type,
        entity_id:    entry.entity_id,
        before_state: entry.before_state,
        after_state:  entry.after_state,
        metadata:     entry.metadata,
        occurred_at:  entry.occurred_at&.iso8601,
        created_at:   entry.created_at&.iso8601
      }
    end

    # Whitelist of query-string filter keys. Read through this map so we
    # never read `params[:action]` directly — that key is owned by Rails
    # and always returns the controller action name ("index"), which
    # would silently filter every row out.
    def filter_params
      {
        entity_type: params[:entity_type],
        entity_id:   params[:entity_id],
        actor_type:  params[:actor_type],
        # `action` collides with Rails routing param. Accept it under
        # the alternate key `action_name` from the wire as well.
        action:      params[:action_filter] || params[:audit_action],
        from:        params[:from],
        to:          params[:to]
      }
    end

    def parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
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
