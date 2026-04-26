# frozen_string_literal: true

require "securerandom"
require "digest"

module Tenants
  # Generates a fresh API key for a tenant (PRD §5.1 + §11).
  #
  # Shape:
  #   <API_KEY_PREFIX>_<8 alphanumeric>_<urlsafe_base64(32)>
  #
  #   - First 12 chars are the stable `api_key_prefix` (fast DB lookup, cached).
  #   - Full raw key is returned ONCE to the caller.
  #   - Only the SHA-256 hash is ever persisted.
  #
  # Example raw key (len ~55):
  #   vpi_a1b2c3d4_aHR0cHM6Ly9ub3ROZWVkcldoQXRJc0hlcmVh...
  #
  # Callers: `Api::Tenants::RegistrationsController`,
  #          `Api::Tenants::RotateKeyController`,
  #          `vpi:setup` rake task.
  class ApiKeyGenerator
    PREFIX_SUFFIX_LENGTH = 8 # chars after `<env-prefix>_`
    SECRET_BYTES = 32        # 43 chars base64 encoded

    Result = Struct.new(:raw_key, :api_key_prefix, :api_key_hash, keyword_init: true)

    def self.generate(env_prefix: ENV.fetch("API_KEY_PREFIX", "vpi"))
      # `<env>` is typically 3 chars ("vpi"); pad/truncate so the total prefix
      # is exactly `Tenant::API_KEY_PREFIX_LENGTH` (12). Format is:
      # `<env>_<random>` — `env + _` contributes `env.length + 1`; the random
      # suffix fills the remainder.
      env_slice = env_prefix.to_s.downcase.gsub(/[^a-z0-9]/, "")
      env_slice = env_slice[0, Tenant::API_KEY_PREFIX_LENGTH - 2] # leave room for _ + at least 1 random
      random_suffix_len = Tenant::API_KEY_PREFIX_LENGTH - env_slice.length - 1
      random_suffix = SecureRandom.alphanumeric(random_suffix_len).downcase
      prefix = "#{env_slice}_#{random_suffix}"

      raise "internal: api_key_prefix length mismatch (#{prefix.inspect})" unless prefix.length == Tenant::API_KEY_PREFIX_LENGTH

      secret = SecureRandom.urlsafe_base64(SECRET_BYTES)
      raw_key = "#{prefix}_#{secret}"

      Result.new(
        raw_key: raw_key,
        api_key_prefix: prefix,
        api_key_hash: Digest::SHA256.hexdigest(raw_key)
      )
    end
  end
end
