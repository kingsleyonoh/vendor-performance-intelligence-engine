# frozen_string_literal: true

# Rails' `process_action.action_controller` notification payload includes
# params + controller + action but NOT `request.request_id`. For controllers
# that bypass our `ApplicationController` / `Api::BaseController` (e.g.
# `Rails::HealthController#show` at `/up`) the app-level `before_action`
# that copies request_id into `Current.request_id` never runs, so the
# lograge custom_options lambda has nothing to emit.
#
# This shim adds `request_id` into the instrumentation payload via
# `append_info_to_payload`, the documented Rails hook for controller-level
# payload augmentation. Lograge reads `event.payload[:request_id]`.
module RequestIdInstrumentation
  def append_info_to_payload(payload)
    super
    payload[:request_id] = request.request_id if request
  end
end

ActiveSupport.on_load(:action_controller_base) do
  prepend RequestIdInstrumentation
end

ActiveSupport.on_load(:action_controller_api) do
  prepend RequestIdInstrumentation
end
