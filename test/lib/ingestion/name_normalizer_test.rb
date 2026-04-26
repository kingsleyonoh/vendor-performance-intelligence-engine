# frozen_string_literal: true

require "test_helper"

# Ingestion::NameNormalizer — PRD §5.2. Pure function that collapses a raw
# vendor name (as seen in source payloads) into a deterministic key used by
# the vendor resolver's fuzzy-match layer. The transform MUST be:
#
#   - locale-insensitive (DE umlauts -> ASCII, "Hauptstraße" -> "hauptstrasse")
#   - legal-form stripped (gmbh, inc, llc, ltd, sa, sarl, sas, ag, ug, ohg,
#     kg, plc, limited, corp, corporation, co, llp, holdings, company)
#   - whitespace-collapsed (runs of whitespace -> single space)
#   - punctuation-trimmed around the edges
#
# Every change to this file invalidates the vendor alias hit-rate — run a
# full regression AND eyeball a sampling of real vendor names before
# tweaking the suffix list.
class NameNormalizerTest < ActiveSupport::TestCase
  def normalize(name)
    Ingestion::NameNormalizer.call(name)
  end

  test "lowercases input" do
    assert_equal "acme", normalize("ACME")
  end

  test "strips DE GmbH legal suffix" do
    assert_equal "acme", normalize("Acme GmbH")
  end

  test "strips US Inc legal suffix" do
    assert_equal "globex international", normalize("Globex International, Inc.")
  end

  test "strips UK Ltd legal suffix" do
    # Note: "Holdings" is also in LEGAL_SUFFIXES so "RBS Holdings Ltd"
    # strips from the tail until only "rbs" remains. The suffix list is
    # aggressive on purpose — false-positive collapses are surfaced by
    # the resolver's tax_id preference in rung 2.
    assert_equal "rbs", normalize("RBS Holdings Ltd")
  end

  test "stops stripping when a non-suffix token is hit" do
    assert_equal "rbs steel", normalize("RBS Steel Ltd")
  end

  test "transliterates non-ASCII umlauts and eszett" do
    assert_equal "hauptstrasse tech", normalize("  Hauptstraße  Tech  KG  ")
  end

  test "collapses runs of whitespace" do
    assert_equal "multi space", normalize("MULTI SPACE    Corp")
  end

  test "strips punctuation padding at edges" do
    assert_equal "foo", normalize("...Foo!!!")
  end

  test "normalises curly apostrophes to straight then strips" do
    # Test that curly-quote is normalized. Straight apostrophe kept as-is
    # within token (o'brien -> o'brien). No weird substitutions here.
    assert_equal "o'brien", normalize("O’Brien Ltd")
  end

  test "strips multiple stacked legal suffixes" do
    # Real-world: "Foo Holdings LLC"
    assert_equal "foo", normalize("Foo Holdings LLC")
  end

  test "leaves no leading/trailing whitespace" do
    result = normalize("   Zeta Services LLP   ")
    assert_equal result, result.strip
    assert_equal "zeta services", result
  end

  test "raises ArgumentError on nil" do
    assert_raises(ArgumentError) { normalize(nil) }
  end

  test "raises ArgumentError on blank string" do
    assert_raises(ArgumentError) { normalize("   ") }
  end

  test "idempotent: normalize(normalize(x)) == normalize(x)" do
    raw = "Acme GmbH"
    once = normalize(raw)
    twice = normalize(once)
    assert_equal once, twice
  end

  test "does not strip legal-suffix-looking tokens mid-name" do
    # "inc" inside a word like "including" must NOT be stripped.
    # We strip the trailing suffix token only.
    assert_equal "including tech", normalize("including tech")
  end

  test "handles only-legal-suffix input" do
    # Edge: all of the input is stripped. Fall back to stripped original
    # (empty after stripping). Expectation: empty string is the normalized
    # form of an all-suffix string. The caller (resolver) decides what to
    # do with that (e.g. reject or use source_ref fallback).
    assert_equal "", normalize("GmbH")
  end
end
