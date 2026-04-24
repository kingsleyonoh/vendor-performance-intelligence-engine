# frozen_string_literal: true

module Ingestion
  # Pure function: raw vendor name -> deterministic fuzzy-match key.
  #
  # Strategy (see `.agent/knowledge/foundation/name-normalization.md` for the
  # full decision log):
  #
  #   1. Unicode NFKD normalize + manual eszett expansion ("ß" -> "ss") +
  #      strip combining marks (umlauts, accents) -> ASCII-ish.
  #   2. Downcase.
  #   3. Normalize curly apostrophes to straight (U+2019 -> U+0027).
  #   4. Collapse non-[a-z0-9' ] characters to spaces (keeps word boundaries).
  #   5. Tokenize on whitespace.
  #   6. Repeatedly strip trailing tokens that appear in LEGAL_SUFFIXES until
  #      the tail no longer matches (handles stacked suffixes like
  #      "Foo Holdings LLC").
  #   7. Rejoin with single spaces.
  #
  # See PRD §5.2. Breaking changes to this function invalidate every alias
  # hit-rate — bump a knowledge-base gotcha before tuning suffixes.
  class NameNormalizer
    LEGAL_SUFFIXES = %w[
      gmbh ag ug ohg kg
      sa sarl sas
      ltd plc limited
      inc llc corp corporation co llp
      holdings company
    ].freeze

    class << self
      def call(raw)
        raise ArgumentError, "name must be a String" if raw.nil?
        raise ArgumentError, "name must not be blank" if raw.to_s.strip.empty?

        downcased = transliterate_to_ascii_ish(raw.to_s).downcase
        normalized_apostrophes = downcased.tr("’", "'")

        # Replace anything not a-z / 0-9 / apostrophe / space with a space
        # so we keep word boundaries. Then collapse runs of whitespace.
        cleaned = normalized_apostrophes.gsub(/[^a-z0-9' ]/, " ")
        cleaned = cleaned.squeeze(" ").strip

        tokens = cleaned.split(" ")
        tokens = strip_trailing_legal_suffixes(tokens)

        tokens.join(" ").strip
      end

      private

      # Apply Unicode NFKD then expand the German eszett explicitly (it
      # does NOT decompose under NFKD), then drop combining marks.
      def transliterate_to_ascii_ish(str)
        nfkd = str.unicode_normalize(:nfkd)
        expanded = nfkd.gsub("ß", "ss").gsub("ẞ", "SS")
        # Drop combining diacritical marks (U+0300..U+036F) and a few
        # common NFKD leftovers.
        expanded.gsub(/[̀-ͯ]/, "")
      end

      def strip_trailing_legal_suffixes(tokens)
        tokens = tokens.dup
        while tokens.any? && LEGAL_SUFFIXES.include?(tokens.last.gsub(/[^a-z]/, ""))
          tokens.pop
        end
        tokens
      end
    end
  end
end
