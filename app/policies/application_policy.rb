# frozen_string_literal: true

# Base policy for all VPI resources. v1 has no per-tenant user-role model
# (the API-key holder IS the admin — see Batch 007 DESIGN_DECISION).
# `:user` is re-declared `allow_nil: true` so the default `ActionPolicy::Base`
# context doesn't fail closed when the controller hasn't set a user.
# `:tenant` is added as a first-class context, populated by the controller
# from Current.tenant via `current_tenant`.
class ApplicationPolicy < ActionPolicy::Base
  authorize :user, allow_nil: true
  authorize :tenant
end
