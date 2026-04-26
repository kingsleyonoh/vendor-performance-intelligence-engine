# frozen_string_literal: true

require "test_helper"

# Tenant model — see PRD §4.1 + §4.T for column specs. Every §4.T identity
# column is bound by at least one template surface (PDF, email, UI, Hub
# payload). Missing columns or missing validations here break every
# downstream template test under strict-undefined rendering.
class TenantTest < ActiveSupport::TestCase
  def valid_attributes
    {
      name: "Test Tenant",
      slug: "test-tenant-de",
      api_key_hash: "a" * 64,
      api_key_prefix: "vpi_test_abc",
      legal_name: "Test GmbH",
      full_legal_name: "Test Procurement GmbH",
      display_name: "Test",
      address: { "line1" => "Somewhere 1", "city" => "Berlin", "country_code" => "DE" },
      registration: { "company_number" => "HRB-1", "jurisdiction" => "DE" },
      contact: { "email" => "ops@test.example" },
      brand_primary_hex: "#0D0D0F",
      brand_accent_hex: "#3B82F6",
      locale: "de-DE",
      timezone: "Europe/Berlin"
    }
  end

  test "is valid with full attributes" do
    tenant = Tenant.new(valid_attributes)
    assert tenant.valid?, tenant.errors.full_messages.to_sentence
  end

  test "requires slug" do
    tenant = Tenant.new(valid_attributes.merge(slug: nil))
    assert_not tenant.valid?
    assert_includes tenant.errors[:slug], "can't be blank"
  end

  test "slug rejects characters outside [a-z0-9-]" do
    # "Upper-Slug" and "MIXED-case" normalize to lowercase -> valid.
    # Spaces, underscores, punctuation are invalid even after normalize.
    ["has space", "under_score", "bad!", "double--start-"].each do |bad|
      tenant = Tenant.new(valid_attributes.merge(slug: bad))
      # Give normalize a chance, then assert validity.
      unless tenant.valid?
        assert_includes tenant.errors[:slug].to_s, "lowercase alphanumeric"
      end
      assert_not tenant.valid?, "expected slug #{bad.inspect} invalid"
    end
  end

  test "slug is normalized to lowercase on save" do
    tenant = Tenant.new(valid_attributes.merge(slug: "MIXED-case-99"))
    # Normalization strips + lowercases BEFORE format validation.
    assert tenant.valid?, tenant.errors.full_messages.to_sentence
    assert_equal "mixed-case-99", tenant.slug
  end

  test "api_key_prefix must be exactly 12 chars" do
    ["short", "a" * 11, "a" * 13].each do |bad|
      tenant = Tenant.new(valid_attributes.merge(api_key_prefix: bad))
      assert_not tenant.valid?, "expected prefix #{bad.length} chars invalid"
    end
  end

  test "api_key_hash uniqueness enforced" do
    tenants(:acme_gmbh_de) # load fixtures
    dup = Tenant.new(valid_attributes.merge(
      slug: "other-slug",
      api_key_prefix: "vpi_unq_abcd",
      api_key_hash: tenants(:acme_gmbh_de).api_key_hash
    ))
    assert_not dup.valid?
    assert_includes dup.errors[:api_key_hash], "has already been taken"
  end

  test "api_key_prefix uniqueness enforced" do
    tenants(:acme_gmbh_de)
    dup = Tenant.new(valid_attributes.merge(
      slug: "other-slug-2",
      api_key_hash: ("b" * 64),
      api_key_prefix: tenants(:acme_gmbh_de).api_key_prefix
    ))
    assert_not dup.valid?
    assert_includes dup.errors[:api_key_prefix], "has already been taken"
  end

  test "brand_primary_hex must match #RRGGBB format" do
    ["red", "#FFF", "123456", "#GG0000"].each do |bad|
      tenant = Tenant.new(valid_attributes.merge(brand_primary_hex: bad))
      assert_not tenant.valid?, "expected hex #{bad.inspect} invalid"
    end
  end

  test "brand_accent_hex must match #RRGGBB format" do
    tenant = Tenant.new(valid_attributes.merge(brand_accent_hex: "not-a-hex"))
    assert_not tenant.valid?
    assert_includes tenant.errors[:brand_accent_hex], "must be a #RRGGBB hex color"
  end

  test "locale must be BCP47 shape xx-XX" do
    ["en", "english", "en_US", "EN-US-extra"].each do |bad|
      tenant = Tenant.new(valid_attributes.merge(locale: bad))
      assert_not tenant.valid?, "expected locale #{bad.inspect} invalid"
    end
  end

  test "address/registration/contact default to empty hash on DB insert" do
    tenant = Tenant.create!(valid_attributes.except(:address, :registration, :contact))
    tenant.reload
    assert_equal({}, tenant.address)
    assert_equal({}, tenant.registration)
    assert_equal({}, tenant.contact)
  end

  test "is_active defaults to true" do
    tenant = Tenant.create!(valid_attributes)
    assert_equal true, tenant.is_active
  end

  test "fixtures load cleanly with distinct identity values" do
    acme = tenants(:acme_gmbh_de)
    globex = tenants(:globex_inc_us)
    assert_not_equal acme.legal_name, globex.legal_name
    assert_not_equal acme.locale, globex.locale
    assert_not_equal acme.timezone, globex.timezone
    assert_not_equal acme.address["country_code"], globex.address["country_code"]
  end
end
