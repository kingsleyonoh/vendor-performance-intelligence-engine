require "application_system_test_case"

# Vendor Detail "Background & Relationships" Card — PRD §5.7, §8, §13.3.
#
# Surfaces `vendors.metadata.rag_enrichment` produced by `RagEnrichmentJob`
# on the existing Vendor Detail page. Hidden when the feature is disabled
# OR when the vendor has no enrichment data.
class VendorDetailRagCardTest < ApplicationSystemTestCase
  setup do
    @prev_rag_flag = ENV["RAG_PLATFORM_ENABLED"]
  end

  teardown do
    ENV["RAG_PLATFORM_ENABLED"] = @prev_rag_flag
  end

  test "renders RAG enrichment card when feature enabled and metadata.rag_enrichment present" do
    ENV["RAG_PLATFORM_ENABLED"] = "true"
    vendor = vendors(:acme_alpha)
    vendor.update_columns(metadata: vendor.metadata.merge(
      "rag_document_count" => 4,
      "rag_enrichment" => {
        "fetched_at" => "2026-04-25T03:00:00Z",
        "entities"   => [
          {
            "id" => "ent-1", "name" => "Alpha Holdings AG", "type" => "parent",
            "relationships" => [{ "type" => "owns", "target" => "Alpha Maschinenbau AG" }]
          },
          {
            "id" => "ent-2", "name" => "Beta Subsidiary GmbH", "type" => "subsidiary",
            "relationships" => [{ "type" => "controlled_by", "target" => "Alpha Maschinenbau AG" }]
          }
        ]
      }
    ))

    sign_in_as "admin@example.com", "password123"
    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=rag-enrichment-card]"
    assert_selector "[data-testid=rag-entity-row]", count: 2
    assert_text "Alpha Holdings AG"
    assert_text "Beta Subsidiary GmbH"
  end

  test "hides card when feature flag is disabled" do
    ENV["RAG_PLATFORM_ENABLED"] = "false"
    vendor = vendors(:acme_alpha)
    vendor.update_columns(metadata: vendor.metadata.merge(
      "rag_enrichment" => {
        "fetched_at" => "2026-04-25T03:00:00Z",
        "entities"   => [{ "id" => "ent-1", "name" => "Should Not Render" }]
      }
    ))

    sign_in_as "admin@example.com", "password123"
    visit "/vendors/#{vendor.id}"

    assert_no_selector "[data-testid=rag-enrichment-card]"
    assert_no_text "Should Not Render"
  end

  test "hides card when no enrichment data" do
    ENV["RAG_PLATFORM_ENABLED"] = "true"
    vendor = vendors(:acme_alpha)
    # Reset metadata cleanly (no rag_enrichment key)
    vendor.update_columns(metadata: { "rag_document_count" => 0 })

    sign_in_as "admin@example.com", "password123"
    visit "/vendors/#{vendor.id}"

    assert_no_selector "[data-testid=rag-enrichment-card]"
  end

  test "shows empty-entities state when enrichment ran but RAG returned zero" do
    ENV["RAG_PLATFORM_ENABLED"] = "true"
    vendor = vendors(:acme_alpha)
    vendor.update_columns(metadata: vendor.metadata.merge(
      "rag_enrichment" => { "fetched_at" => "2026-04-25T03:00:00Z", "entities" => [] }
    ))

    sign_in_as "admin@example.com", "password123"
    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=rag-enrichment-card]"
    assert_selector "[data-testid=rag-empty]"
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
