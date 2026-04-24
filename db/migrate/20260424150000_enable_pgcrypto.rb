# frozen_string_literal: true

# Enables pgcrypto so UUID primary keys can default to gen_random_uuid().
# This must run before any table that wants UUID PKs.
class EnablePgcrypto < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
  end
end
