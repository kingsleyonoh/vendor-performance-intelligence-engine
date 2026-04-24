Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # ----------------------------------------------------------------
  # API surface — PRD §8b
  # ----------------------------------------------------------------
  namespace :api do
    # Tenant identity + self-registration + rotation (PRD §5.1 + §8b).
    # `register` is public (allowlisted in ApiKeyAuthenticator);
    # `me` + `me/rotate-key` require a valid X-API-Key.
    post "tenants/register",       to: "tenants/registrations#create"
    get  "tenants/me",             to: "tenants/me#show"
    post "tenants/me/rotate-key",  to: "tenants/rotate_key#create"

    # Vendor CRUD (PRD §5.2 + §8b) + nested alias CRUD + top-level
    # pending-alias queue.
    get "aliases/pending", to: "vendor_aliases#pending", as: :pending_aliases

    resources :vendors do
      resources :aliases, controller: "vendor_aliases"
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
