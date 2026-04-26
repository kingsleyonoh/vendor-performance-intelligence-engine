# frozen_string_literal: true

module Api
  module Ingestion
    # CRUD for /api/ingestion/sources — PRD §5, §8b.
    #
    # Enforces the secret-reference policy via `Ingestion::SourceContract`:
    # `connection_config.api_key_ref` etc. must be `ENV:VAR_NAME`, never raw
    # secrets. Soft-delete: DELETE flips `is_enabled` to false rather than
    # removing the row (because `ingestion_runs` FK references survive).
    class SourcesController < ::Api::BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE     = 200

      before_action :load_source, only: %i[show update destroy]

      def index
        authorize! IngestionSource, with: IngestionSourcePolicy
        scope = tenant_scope
        scope = scope.where(source_system: params[:source_system]) if params[:source_system].present?
        if params[:is_enabled].present?
          scope = scope.where(is_enabled: ActiveModel::Type::Boolean.new.cast(params[:is_enabled]))
        end

        page, per_page = pagination_params
        total = scope.count
        paged = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          ingestion_sources: IngestionSourceSerializer.new(paged).serializable_hash,
          pagination: {
            page: page, per_page: per_page,
            total_count: total, total_pages: (total.to_f / per_page).ceil
          }
        }, status: :ok
      end

      def show
        authorize! @source, with: IngestionSourcePolicy
        render json: { ingestion_source: IngestionSourceSerializer.new(@source).serializable_hash },
               status: :ok
      end

      def create
        authorize! IngestionSource, with: IngestionSourcePolicy
        body = request_body
        result = ::Ingestion::SourceContract.new.call(body)
        return render_validation(result) if result.failure?

        attrs = result.to_h.merge(tenant: Current.tenant)
        attrs[:connection_config] = (attrs[:connection_config] || {}).deep_stringify_keys
        source = IngestionSource.new(attrs)
        if source.save
          render json: { ingestion_source: IngestionSourceSerializer.new(source).serializable_hash },
                 status: :created
        else
          render_model_validation_error(source)
        end
      rescue ActiveRecord::RecordNotUnique
        render_api_error(::Errors::JsonApiError::CONFLICT,
                         message: "Ingestion source already exists for this source_system.")
      end

      def update
        authorize! @source, with: IngestionSourcePolicy
        body = request_body

        # Partial update — merge current attrs so contract sees full shape.
        merged = current_attrs.merge(body.slice(*allowed_update_keys))
        result = ::Ingestion::SourceContract.new.call(merged)
        return render_validation(result) if result.failure?

        update_attrs = body.slice(*allowed_update_keys)
        if update_attrs.key?(:connection_config) && update_attrs[:connection_config]
          update_attrs[:connection_config] = update_attrs[:connection_config].deep_stringify_keys
        end

        if @source.update(update_attrs)
          render json: { ingestion_source: IngestionSourceSerializer.new(@source).serializable_hash },
                 status: :ok
        else
          render_model_validation_error(@source)
        end
      end

      # Soft-delete: flip is_enabled=false. Preserves the row so existing
      # ingestion_runs FK references remain valid for audit history.
      def destroy
        authorize! @source, with: IngestionSourcePolicy
        @source.update_columns(is_enabled: false, updated_at: Time.now.utc)
        render json: { ingestion_source: IngestionSourceSerializer.new(@source).serializable_hash },
               status: :ok
      end

      private

      def tenant_scope
        IngestionSource.where(tenant_id: Current.tenant.id)
      end

      def load_source
        @source = tenant_scope.find(params[:id])
      end

      def allowed_update_keys
        %i[is_enabled connection_config pull_mode pull_interval_minutes]
      end

      def current_attrs
        {
          source_system: @source.source_system,
          is_enabled: @source.is_enabled,
          connection_config: @source.connection_config || {},
          pull_mode: @source.pull_mode,
          pull_interval_minutes: @source.pull_interval_minutes
        }
      end

      def render_validation(result)
        render_api_error(::Errors::JsonApiError::VALIDATION_ERROR,
                         message: "Validation failed.",
                         details: ::Ingestion::SourceContract.details_for(result))
      end

      def render_model_validation_error(record)
        details = record.errors.map { |err| { path: err.attribute.to_s, issue: err.message } }
        render_api_error(::Errors::JsonApiError::VALIDATION_ERROR,
                         message: "Validation failed.", details: details)
      end

      def request_body
        raw = request.request_parameters
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        inner = raw["ingestion_source"] || raw[:ingestion_source] || raw
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
end
