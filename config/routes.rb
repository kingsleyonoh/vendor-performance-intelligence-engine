Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # ----------------------------------------------------------------
  # API surface — PRD §8b
  # ----------------------------------------------------------------
  namespace :api do
    # Health checks — PRD §8, §10b. Public (allowlisted in
    # Auth::ApiKeyAuthenticator). Order matters: the allowlist matches the
    # exact request path, so routes must emit the same paths the
    # middleware expects.
    get "health",        to: "health#index"
    get "health/db",     to: "health#db"
    get "health/redis",  to: "health#redis"
    get "health/ready",  to: "health#ready"

    # Tenant identity + self-registration + rotation (PRD §5.1 + §8b).
    # `register` is public (allowlisted in ApiKeyAuthenticator);
    # `me` + `me/rotate-key` require a valid X-API-Key.
    post "tenants/register",       to: "tenants/registrations#create"
    get  "tenants/me",             to: "tenants/me#show"
    post "tenants/me/rotate-key",  to: "tenants/rotate_key#create"

    # Vendor CRUD (PRD §5.2 + §8b) + nested alias CRUD + top-level
    # pending-alias queue.
    get "aliases/pending", to: "vendor_aliases#pending", as: :pending_aliases

    # Signal ingestion (PRD §5.3 + §8b). Single + batch shapes accepted.
    post "signals", to: "signals#create"

    # Scoring rules CRUD + activate + preview — PRD §4.6, §5, §8b.
    resources :scoring_rules do
      member do
        post :activate
        post :preview
      end
    end

    resources :vendors do
      resources :aliases, controller: "vendor_aliases"

      # Read surface for scores + signals (PRD §8b).
      scope module: :vendors do
        resource :score, only: [], controller: "scores" do
          get :current
          get :history
        end
        resources :signals, only: [:index]
      end

      # POST /api/vendors/:id/merge — PRD §5.2. Collapses duplicate vendor.
      post :merge, to: "vendors/merge#create", on: :member
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
