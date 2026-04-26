# frozen_string_literal: true

# Vendors::IndexQuery — PRD §5b. Filter + sort + paginate the vendors
# list, AND fetch the latest `vendor_scores` row per returned vendor so
# the row component can render band + composite_score without N+1 lookups.
#
# Returns [vendors_relation_paginated, latest_scores_by_vendor_id_hash].
module Vendors
  class IndexQuery
    ALLOWED_SORTS = %w[canonical_name annual_spend_cents status updated_at].freeze

    def self.call(tenant_id:, filters:, per_page: 25)
      new(tenant_id: tenant_id, filters: filters, per_page: per_page).call
    end

    def initialize(tenant_id:, filters:, per_page:)
      @tenant_id = tenant_id
      @filters = filters
      @per_page = per_page
    end

    def call
      scope = Vendor.where(tenant_id: @tenant_id)
      scope = apply_status_filter(scope)
      scope = apply_category_filter(scope)
      scope = apply_spend_filter(scope)
      scope = apply_search_filter(scope)
      scope = apply_band_filter(scope)
      scope = apply_sort(scope)
      scope = apply_pagination(scope)

      vendors_arr = scope.to_a
      latest_scores = load_latest_scores(vendors_arr.map(&:id))
      [vendors_arr, latest_scores]
    end

    private

    def apply_status_filter(scope)
      return scope if @filters[:status].empty?
      scope.where(status: @filters[:status])
    end

    def apply_category_filter(scope)
      return scope if @filters[:category].empty?
      scope.where(category: @filters[:category])
    end

    def apply_spend_filter(scope)
      scope = scope.where("annual_spend_cents >= ?", @filters[:min_spend]) if @filters[:min_spend]
      scope = scope.where("annual_spend_cents <= ?", @filters[:max_spend]) if @filters[:max_spend]
      scope
    end

    def apply_search_filter(scope)
      return scope if @filters[:search].blank?
      scope.where("canonical_name ILIKE ?", "%#{@filters[:search]}%")
    end

    def apply_band_filter(scope)
      return scope if @filters[:band].empty?
      # Resolve banded vendor_ids via latest scores, then filter scope.
      sql = <<~SQL
        SELECT vendor_id FROM (
          SELECT DISTINCT ON (vendor_id) vendor_id, band
          FROM vendor_scores
          WHERE tenant_id = $1
          ORDER BY vendor_id, computed_at DESC
        ) latest
        WHERE band = ANY($2)
      SQL
      rows = VendorScore.connection.exec_query(
        sql, "IndexQuery.BandFilter",
        [@tenant_id, "{#{@filters[:band].join(',')}}"]
      )
      ids = rows.rows.flatten
      scope.where(id: ids)
    end

    def apply_sort(scope)
      column = ALLOWED_SORTS.include?(@filters[:sort]) ? @filters[:sort] : "canonical_name"
      direction = @filters[:direction]
      scope.order(Arel.sql("#{column} #{direction.upcase}"))
    end

    def apply_pagination(scope)
      page = [@filters[:page], 1].max
      scope.limit(@per_page).offset((page - 1) * @per_page)
    end

    def load_latest_scores(vendor_ids)
      return {} if vendor_ids.empty?

      sql = <<~SQL
        SELECT DISTINCT ON (vendor_id) vendor_id, band, composite_score, trend, computed_at
        FROM vendor_scores
        WHERE tenant_id = $1 AND vendor_id = ANY($2)
        ORDER BY vendor_id, computed_at DESC
      SQL
      result = VendorScore.connection.exec_query(
        sql, "IndexQuery.LatestScores",
        [@tenant_id, "{#{vendor_ids.join(',')}}"]
      )
      result.each_with_object({}) do |row, h|
        h[row["vendor_id"]] = {
          band: row["band"],
          composite_score: row["composite_score"].to_f,
          trend: row["trend"],
          computed_at: row["computed_at"]
        }
      end
    end
  end
end
