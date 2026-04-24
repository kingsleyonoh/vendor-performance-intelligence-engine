# `rails new` fails on placeholder `RAILS_MASTER_KEY`

- **Symptom:** Running `rails new` against an existing project directory that already has `.env.local` (or any env file loaded by dotenv-rails) containing `RAILS_MASTER_KEY=replace_me_after_rails_new` (or any non-32-hex string) crashes the credentials generator with:

  ```
  ActiveSupport::EncryptedFile::InvalidKeyLengthError:
    Encryption key must be exactly 32 characters.
  ```

  Stack trace points at `railties-8.0.x/lib/rails/generators/rails/credentials/credentials_generator.rb:15`. The new Rails app is created BUT the scaffolder leaves the `config/` dir in a half-finished state.

- **Cause:** Rails' credentials generator calls `ActiveSupport::EncryptedFile#write`, which calls `check_key_length`. `check_key_length` reads the key via `read_env_key || read_key_file` — so if `RAILS_MASTER_KEY` is set in the environment (or via dotenv), it wins over `config/master.key`. Rails 8 uses `aes-128-gcm` → 32-char hex (16 bytes). A placeholder like `replace_me_after_rails_new` (25 chars) fails the length check and the scaffold aborts mid-run.

  Related trap: after scaffolding, if `DATABASE_URL=postgresql://...@postgres:5432/vpi_development` is set in `.env.local` or compose, Rails pins that database regardless of `RAILS_ENV`, so `RAILS_ENV=test bin/rails db:create` creates `vpi_development` (or fails with "already exists") and `vpi_test` never gets created.

- **Solution:**
  1. BEFORE `rails new`: remove or comment-out `RAILS_MASTER_KEY` / `SECRET_KEY_BASE` from `.env.local` (and any other dotenv file Rails will load). A missing env var is safe — Rails will write `config/master.key` and read from there.
  2. AFTER `rails new`: copy the actual 32-hex value from `config/master.key` into `.env.local` as `RAILS_MASTER_KEY=...` and generate a SecureRandom hex(64) for `SECRET_KEY_BASE`.
  3. Do NOT set `DATABASE_URL` in `.env.local` or compose `environment:` if you want `config/database.yml`'s per-env sections (development vs test) to resolve correctly. Use `POSTGRES_HOST/USER/PASSWORD/DB` + `POSTGRES_TEST_DB` instead — those let `database.yml` swap DB names per `Rails.env`.

  Canonical `.env.local.example` template for future VPI clones:

  ```
  # After rails new, replace with the 32-hex value from config/master.key.
  RAILS_MASTER_KEY=copy_32_hex_chars_from_config_master_key
  SECRET_KEY_BASE=copy_securerandom_hex_64
  # Leave DATABASE_URL UNSET so RAILS_ENV swaps dev↔test correctly.
  POSTGRES_HOST=postgres
  POSTGRES_USER=vpi_user
  POSTGRES_PASSWORD=vpi_dev_pw
  POSTGRES_DB=vpi_development
  POSTGRES_TEST_DB=vpi_test
  ```

- **Discovered in:** Vendor Performance Intelligence Engine, Batch 002 (2026-04-24).

- **Affects:** Rails 8.0.x with dotenv-rails, Ruby 3.3.x, any project that pre-creates `.env.local` before `rails new`. Applies any time `.env.local` is authored in a bootstrap batch that precedes the Rails scaffold (i.e. the VPI pattern of "author compose + .env.local first, then scaffold Rails").
