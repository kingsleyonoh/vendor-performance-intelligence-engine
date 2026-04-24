# frozen_string_literal: true

module Api
  # CRUD for /api/vendors — PRD §8b.
  #
  # Tenant scoping flows through `Current.tenant`, set by
  # `Auth::ApiKeyAuthenticator`. Cross-tenant lookups return 404 (never 403/200)
  # via the `.find_by!` raising `ActiveRecord::RecordNotFound`, which the
  # base controller renders as NOT_FOUND.
  class VendorsController < ::Api::BaseController
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE     = 200
    UPDATE_ATTRS = %i[canonical_name category status annual_spend_cents currency country_code metadata].freeze
    CREATE_ATTRS = %i[canonical_name tax_id country_code category annual_spend_cents currency status metadata].freeze

    before_action :load_vendor, only: %i[show update destroy]

    def index
      authorize! Vendor, with: VendorPolicy

      scope = tenant_scope
      scope = scope.where(status: params[:status])           if params[:status].present?
      scope = scope.where(category: params[:category])       if params[:category].present?
      scope = scope.where(country_code: params[:country_code]) if params[:country_code].present?
      if params[:search].present?
        pattern = "%#{params[:search].to_s.downcase}%"
        scope = scope.where("LOWER(canonical_name) LIKE ?", pattern)
      end

      page, per_page = pagination_params
      total = scope.count
      paged = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

      render json: {
        vendors: VendorSerializer.new(paged).serializable_hash,
        pagination: {
          page: page,
          per_page: per_page,
          total_count: total,
          total_pages: (total.to_f / per_page).ceil
        }
      }, status: :ok
    end

    def show
      authorize! @vendor, with: VendorPolicy
      render json: { vendor: VendorSerializer.new(@vendor).serializable_hash }, status: :ok
    end

    def create
      authorize! Vendor, with: VendorPolicy

      vendor = tenant_scope.new(create_params)
      if vendor.save
        render json: { vendor: VendorSerializer.new(vendor).serializable_hash }, status: :created
      else
        render_model_validation_error(vendor)
      end
    end

    def update
      authorize! @vendor, with: VendorPolicy

      if @vendor.update(update_params)
        render json: { vendor: VendorSerializer.new(@vendor).serializable_hash }, status: :ok
      else
        render_model_validation_error(@vendor)
      end
    end

    def destroy
      authorize! @vendor, with: VendorPolicy

      @vendor.update!(status: "terminated")
      render json: { vendor: VendorSerializer.new(@vendor).serializable_hash }, status: :ok
    end

    private

    def tenant_scope
      Vendor.where(tenant_id: Current.tenant.id)
    end

    def load_vendor
      @vendor = tenant_scope.find(params[:id])
    end

    def create_params
      body = request_body
      body.slice(*CREATE_ATTRS)
    end

    def update_params
      body = request_body
      body.slice(*UPDATE_ATTRS)
    end

    # Accepts both top-level JSON hashes and `{ "vendor": {...} }` envelopes.
    def request_body
      raw = request.request_parameters
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      inner = raw["vendor"] || raw[:vendor] || raw
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

    def render_model_validation_error(record)
      details = record.errors.map { |err| { path: err.attribute.to_s, issue: err.message } }
      render_api_error(
        ::Errors::JsonApiError::VALIDATION_ERROR,
        message: "Validation failed.",
        details: details
      )
    end
  end
end
