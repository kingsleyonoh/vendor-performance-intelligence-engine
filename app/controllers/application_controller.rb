class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Propagate ActionDispatch::RequestId -> Current.request_id so Lograge
  # (config/initializers/lograge.rb) and Audit::Recorder can correlate log
  # lines + audit rows + Sentry events for the same request.
  before_action :capture_request_id

  private

  def capture_request_id
    Current.request_id = request.request_id if Current.respond_to?(:request_id=)
  end
end
