Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  # ----------------------------------------------------------------
  # UI surface — PRD §5b, §8. Session-auth-gated operator pages.
  # ----------------------------------------------------------------
  root to: "dashboard#index"

  resources :vendors, only: [:index, :show] do
    collection do
      post :bulk
    end
    member do
      post :terminate
    end
  end

  # UI alert inbox — PRD §5b, §8, §13.2. HTML/Turbo surface, separate from
  # the JSON `Api::AlertsController` under /api/alerts.
  resources :alerts, only: [:index, :show] do
    member do
      post :acknowledge
      post :suppress
      post :retry
    end
  end

  # UI reports surface — PRD §5b, §8, §13.3. HTML/Turbo surface, separate
  # from the JSON `Api::ReportsController` under /api/reports.
  resources :reports, only: [:index, :show, :create] do
    member do
      get :download
    end
  end

  # UI settings → ingestion sources — PRD §8, §13.2. Operator-facing config
  # surface for adapter onboarding (CRUD + manual pull). Separate from the
  # JSON `Api::Ingestion::SourcesController` under /api/ingestion/sources.
  namespace :settings do
    resources :ingestion_sources, path: "ingestion-sources" do
      member do
        post :pull_now
      end
    end

    # Settings → Scoring Rules — PRD §5b, §8, §13.3. Singular resource:
    # the operator manages the single active rule per tenant. Submitting
    # the form CREATEs a new rule and atomically deactivates the previous.
    resource :scoring, only: %i[show create], controller: "scoring"

    # Settings → API Keys — PRD §5b, §8, §13.3. Singular resource: one
    # key per tenant. POST = rotate; the rotated key is shown ONCE.
    resource :api_keys, only: %i[show create], path: "api-keys", controller: "api_keys"
  end

  # Aliases queue UI — PRD §8, §13.3. Operator-facing pending-confirm queue.
  # Distinct from the JSON `Api::VendorAliasesController#pending`.
  resources :vendor_aliases, only: [], path: "aliases" do
    collection do
      get :pending
    end
    member do
      post :confirm
      post :reject
    end
  end

  # Audit Log UI — PRD §5b, §8, §13.3. Read-only operator surface.
  # Distinct from the JSON `Api::AuditLogController#index` under
  # `/api/audit-log`. Singleton GET-only resource at `/audit`.
  get "audit", to: "audit_log#index", as: :audit_log

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

    # Inbound from Notification Hub fanout — HMAC-authenticated (PRD §13.2).
    # Allowlisted in Auth::ApiKeyAuthenticator. Uses underscore form for
    # the route helper while accepting hyphen form on the wire.
    post "signals/from-hub", to: "signals/from_hub#create"

    # Ingestion management (PRD §5, §8b, §13.2).
    namespace :ingestion do
      resources :sources, only: %i[index show create update destroy] do
        member do
          post :pull_now, to: "sources/pull_now#create"
        end
      end
      resources :runs, only: %i[index show]
    end

    # Scoring rules CRUD + activate + preview — PRD §4.6, §5, §8b.
    resources :scoring_rules do
      member do
        post :activate
        post :preview
      end
    end

    # Risk alerts — list/show + lifecycle actions. PRD §5, §8b, §13.2.
    resources :alerts, only: [:index, :show] do
      member do
        post :acknowledge
        post :suppress
        post :retry
      end
    end

    # Reports — list/show/create + download. PRD §5, §8, §8b, §13.3.
    resources :reports, only: [:index, :show, :create] do
      member do
        get :download
      end
    end

    # Audit Log — admin-only read surface. PRD §5, §8, §8b, §13.3.
    # Rows are insert-only at the model layer (PRD §4.12) — no create/
    # update/destroy verbs. Path uses hyphen for the wire form, route
    # helper retains underscore.
    get  "audit-log",     to: "audit_log#index", as: :audit_log_entries
    get  "audit-log/:id", to: "audit_log#show",  as: :audit_log_entry

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
