SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vendor_signals_enforce_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vendor_signals_enforce_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  merge_mode TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'vendor_signals is append-only; DELETE is not permitted (row id=%)', OLD.id;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    merge_mode := current_setting('vpi.signals_merge_mode', true);

    -- In merge mode: only vendor_id, merged_at, and status may change.
    -- Every other locked column must still be unchanged.
    IF merge_mode = 'true' THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
         OR NEW.signal_code IS DISTINCT FROM OLD.signal_code
         OR NEW.source_system IS DISTINCT FROM OLD.source_system
         OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
         OR NEW.value_numeric IS DISTINCT FROM OLD.value_numeric
         OR NEW.value_boolean IS DISTINCT FROM OLD.value_boolean
         OR NEW.context::text IS DISTINCT FROM OLD.context::text
         OR NEW.window_start IS DISTINCT FROM OLD.window_start
         OR NEW.window_end IS DISTINCT FROM OLD.window_end
         OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
         OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
         OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'vendor_signals merge: only vendor_id, merged_at, and status may change (row id=%)', OLD.id;
      END IF;

      -- Status transitions still governed in merge mode.
      IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT (
          (OLD.status = 'raw' AND NEW.status IN ('normalized','rejected'))
          OR (OLD.status = 'normalized' AND NEW.status IN ('scored','superseded'))
        ) THEN
          RAISE EXCEPTION 'vendor_signals: illegal status transition % -> %', OLD.status, NEW.status;
        END IF;
      END IF;

      RETURN NEW;
    END IF;

    -- Non-merge mode: lock vendor_id + merged_at + every other column.
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.vendor_id IS DISTINCT FROM OLD.vendor_id
       OR NEW.signal_code IS DISTINCT FROM OLD.signal_code
       OR NEW.source_system IS DISTINCT FROM OLD.source_system
       OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.value_numeric IS DISTINCT FROM OLD.value_numeric
       OR NEW.value_boolean IS DISTINCT FROM OLD.value_boolean
       OR NEW.context::text IS DISTINCT FROM OLD.context::text
       OR NEW.window_start IS DISTINCT FROM OLD.window_start
       OR NEW.window_end IS DISTINCT FROM OLD.window_end
       OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
       OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.merged_at IS DISTINCT FROM OLD.merged_at THEN
      RAISE EXCEPTION 'vendor_signals is append-only; only `status` may be updated (row id=%)', OLD.id;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NOT (
        (OLD.status = 'raw' AND NEW.status IN ('normalized','rejected'))
        OR (OLD.status = 'normalized' AND NEW.status IN ('scored','superseded'))
      ) THEN
        RAISE EXCEPTION 'vendor_signals: illegal status transition % -> %', OLD.status, NEW.status;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_log_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid,
    actor_type text NOT NULL,
    actor_id text,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id text,
    before_state jsonb,
    after_state jsonb,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ingestion_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingestion_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    ingestion_source_id uuid NOT NULL,
    mode text NOT NULL,
    status text DEFAULT 'running'::text NOT NULL,
    signals_attempted integer DEFAULT 0 NOT NULL,
    signals_stored integer DEFAULT 0 NOT NULL,
    signals_rejected integer DEFAULT 0 NOT NULL,
    signals_deduped integer DEFAULT 0 NOT NULL,
    error_summary text,
    retry_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_at timestamp with time zone NOT NULL,
    finished_at timestamp with time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ingestion_runs_mode_chk CHECK ((mode = ANY (ARRAY['full_backfill'::text, 'incremental'::text, 'webhook_event'::text, 'manual'::text]))),
    CONSTRAINT ingestion_runs_status_chk CHECK ((status = ANY (ARRAY['running'::text, 'succeeded'::text, 'failed'::text, 'partial'::text])))
);


--
-- Name: ingestion_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingestion_sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    source_system text NOT NULL,
    is_enabled boolean DEFAULT false NOT NULL,
    connection_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    pull_mode text DEFAULT 'periodic'::text NOT NULL,
    pull_interval_minutes integer DEFAULT 15,
    last_successful_pull timestamp with time zone,
    last_attempted_pull timestamp with time zone,
    last_failure_reason text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    monitor_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ingestion_sources_pull_mode_chk CHECK ((pull_mode = ANY (ARRAY['periodic'::text, 'webhook_push'::text, 'manual'::text]))),
    CONSTRAINT ingestion_sources_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text])))
);


--
-- Name: risk_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.risk_alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    previous_band text NOT NULL,
    new_band text NOT NULL,
    previous_score numeric(6,3) NOT NULL,
    new_score numeric(6,3) NOT NULL,
    direction text NOT NULL,
    triggered_by_score uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    delivery_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    hub_event_id text,
    workflow_execution_id text,
    dispatch_attempts integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone,
    last_error text,
    acknowledged_at timestamp with time zone,
    acknowledged_by text,
    resolved_at timestamp with time zone,
    suppressed_until timestamp with time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT risk_alerts_direction_chk CHECK ((direction = ANY (ARRAY['escalation'::text, 'improvement'::text]))),
    CONSTRAINT risk_alerts_new_band_chk CHECK ((new_band = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text]))),
    CONSTRAINT risk_alerts_previous_band_chk CHECK ((previous_band = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text]))),
    CONSTRAINT risk_alerts_status_chk CHECK ((status = ANY (ARRAY['pending'::text, 'dispatching'::text, 'delivered'::text, 'acknowledged'::text, 'resolved'::text, 'suppressed'::text, 'failed'::text])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: scoring_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scoring_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    category_weights jsonb NOT NULL,
    signal_weight_overrides jsonb DEFAULT '{}'::jsonb NOT NULL,
    band_thresholds jsonb NOT NULL,
    window_days integer DEFAULT 90 NOT NULL,
    time_decay_half_life_days integer DEFAULT 45 NOT NULL,
    activated_at timestamp with time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT scoring_rules_half_life_chk CHECK ((time_decay_half_life_days > 0)),
    CONSTRAINT scoring_rules_window_days_chk CHECK ((window_days > 0))
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: signal_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.signal_definitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    category text NOT NULL,
    source_system text NOT NULL,
    direction text NOT NULL,
    value_type text NOT NULL,
    default_weight numeric(5,4) DEFAULT 0.0 NOT NULL,
    description text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT signal_definitions_category_chk CHECK ((category = ANY (ARRAY['financial'::text, 'contractual'::text, 'integration'::text, 'transactional'::text]))),
    CONSTRAINT signal_definitions_default_weight_chk CHECK (((default_weight >= 0.0) AND (default_weight <= 1.0))),
    CONSTRAINT signal_definitions_direction_chk CHECK ((direction = ANY (ARRAY['higher_is_worse'::text, 'lower_is_worse'::text]))),
    CONSTRAINT signal_definitions_value_type_chk CHECK ((value_type = ANY (ARRAY['rate'::text, 'count'::text, 'duration_seconds'::text, 'money_cents'::text, 'boolean'::text])))
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    api_key_hash text NOT NULL,
    api_key_prefix text NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    legal_name text DEFAULT ''::text NOT NULL,
    full_legal_name text DEFAULT ''::text NOT NULL,
    display_name text DEFAULT ''::text NOT NULL,
    address jsonb DEFAULT '{}'::jsonb NOT NULL,
    registration jsonb DEFAULT '{}'::jsonb NOT NULL,
    contact jsonb DEFAULT '{}'::jsonb NOT NULL,
    wordmark_url text,
    brand_primary_hex text DEFAULT '#0D0D0F'::text NOT NULL,
    brand_accent_hex text DEFAULT '#3B82F6'::text NOT NULL,
    locale text DEFAULT 'en-US'::text NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: vendor_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_aliases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    source_system text NOT NULL,
    source_ref text NOT NULL,
    alias_text text,
    confidence numeric(4,3) NOT NULL,
    is_confirmed boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT vendor_aliases_confidence_chk CHECK (((confidence >= 0.0) AND (confidence <= 1.0))),
    CONSTRAINT vendor_aliases_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text])))
);


--
-- Name: vendor_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid,
    report_type text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    output_format text NOT NULL,
    parameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    tenant_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    render_context jsonb DEFAULT '{}'::jsonb NOT NULL,
    storage_path text,
    inline_payload text,
    requested_by_user_id bigint,
    generated_at timestamp with time zone,
    expires_at timestamp with time zone,
    error_summary text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT vendor_reports_output_format_chk CHECK ((output_format = ANY (ARRAY['pdf'::text, 'csv'::text, 'json'::text]))),
    CONSTRAINT vendor_reports_report_type_chk CHECK ((report_type = ANY (ARRAY['vendor_scorecard'::text, 'portfolio_risk'::text, 'retender_candidates'::text, 'trend_analysis'::text]))),
    CONSTRAINT vendor_reports_status_chk CHECK ((status = ANY (ARRAY['queued'::text, 'generating'::text, 'ready'::text, 'failed'::text, 'expired'::text])))
);


--
-- Name: vendor_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    scoring_rules_id uuid NOT NULL,
    composite_score numeric(6,3) NOT NULL,
    band text NOT NULL,
    trend text NOT NULL,
    category_scores jsonb NOT NULL,
    top_contributors jsonb DEFAULT '[]'::jsonb NOT NULL,
    window_days integer NOT NULL,
    signals_considered_count integer DEFAULT 0 NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT vendor_scores_band_chk CHECK ((band = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'critical'::text]))),
    CONSTRAINT vendor_scores_composite_range_chk CHECK (((composite_score >= 0.0) AND (composite_score <= 100.0))),
    CONSTRAINT vendor_scores_trend_chk CHECK ((trend = ANY (ARRAY['improving'::text, 'stable'::text, 'degrading'::text, 'new'::text])))
);


--
-- Name: vendor_signals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_signals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    signal_code text NOT NULL,
    source_system text NOT NULL,
    source_event_id text,
    value_numeric numeric(20,4),
    value_boolean boolean,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_start timestamp with time zone,
    window_end timestamp with time zone,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'normalized'::text NOT NULL,
    rejection_reason text,
    supersedes_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    merged_at timestamp with time zone,
    CONSTRAINT vendor_signals_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text]))),
    CONSTRAINT vendor_signals_status_chk CHECK ((status = ANY (ARRAY['raw'::text, 'normalized'::text, 'scored'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT vendor_signals_value_xor_chk CHECK ((((value_numeric IS NOT NULL) AND (value_boolean IS NULL)) OR ((value_boolean IS NOT NULL) AND (value_numeric IS NULL)) OR ((value_numeric IS NULL) AND (value_boolean IS NULL) AND (status = 'rejected'::text))))
)
PARTITION BY RANGE (recorded_at);


--
-- Name: vendor_signals_2026_04; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_signals_2026_04 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    signal_code text NOT NULL,
    source_system text NOT NULL,
    source_event_id text,
    value_numeric numeric(20,4),
    value_boolean boolean,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_start timestamp with time zone,
    window_end timestamp with time zone,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'normalized'::text NOT NULL,
    rejection_reason text,
    supersedes_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    merged_at timestamp with time zone,
    CONSTRAINT vendor_signals_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text]))),
    CONSTRAINT vendor_signals_status_chk CHECK ((status = ANY (ARRAY['raw'::text, 'normalized'::text, 'scored'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT vendor_signals_value_xor_chk CHECK ((((value_numeric IS NOT NULL) AND (value_boolean IS NULL)) OR ((value_boolean IS NOT NULL) AND (value_numeric IS NULL)) OR ((value_numeric IS NULL) AND (value_boolean IS NULL) AND (status = 'rejected'::text))))
);


--
-- Name: vendor_signals_2026_05; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_signals_2026_05 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    signal_code text NOT NULL,
    source_system text NOT NULL,
    source_event_id text,
    value_numeric numeric(20,4),
    value_boolean boolean,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_start timestamp with time zone,
    window_end timestamp with time zone,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'normalized'::text NOT NULL,
    rejection_reason text,
    supersedes_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    merged_at timestamp with time zone,
    CONSTRAINT vendor_signals_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text]))),
    CONSTRAINT vendor_signals_status_chk CHECK ((status = ANY (ARRAY['raw'::text, 'normalized'::text, 'scored'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT vendor_signals_value_xor_chk CHECK ((((value_numeric IS NOT NULL) AND (value_boolean IS NULL)) OR ((value_boolean IS NOT NULL) AND (value_numeric IS NULL)) OR ((value_numeric IS NULL) AND (value_boolean IS NULL) AND (status = 'rejected'::text))))
);


--
-- Name: vendor_signals_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_signals_default (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    signal_code text NOT NULL,
    source_system text NOT NULL,
    source_event_id text,
    value_numeric numeric(20,4),
    value_boolean boolean,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_start timestamp with time zone,
    window_end timestamp with time zone,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'normalized'::text NOT NULL,
    rejection_reason text,
    supersedes_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    merged_at timestamp with time zone,
    CONSTRAINT vendor_signals_source_system_chk CHECK ((source_system = ANY (ARRAY['invoice_recon'::text, 'webhook_engine'::text, 'contract_engine'::text, 'recon_engine'::text, 'rag_platform'::text, 'manual'::text]))),
    CONSTRAINT vendor_signals_status_chk CHECK ((status = ANY (ARRAY['raw'::text, 'normalized'::text, 'scored'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT vendor_signals_value_xor_chk CHECK ((((value_numeric IS NOT NULL) AND (value_boolean IS NULL)) OR ((value_boolean IS NOT NULL) AND (value_numeric IS NULL)) OR ((value_numeric IS NULL) AND (value_boolean IS NULL) AND (status = 'rejected'::text))))
);


--
-- Name: vendors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    canonical_name text NOT NULL,
    normalized_name text NOT NULL,
    tax_id text,
    country_code text,
    category text,
    annual_spend_cents bigint,
    currency text,
    status text DEFAULT 'active'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT vendors_country_code_chk CHECK (((country_code IS NULL) OR (country_code ~ '^[A-Z]{2}$'::text))),
    CONSTRAINT vendors_status_chk CHECK ((status = ANY (ARRAY['active'::text, 'watchlist'::text, 'terminated'::text, 'merged'::text])))
);


--
-- Name: vendor_signals_2026_04; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals ATTACH PARTITION public.vendor_signals_2026_04 FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-05-01 00:00:00+00');


--
-- Name: vendor_signals_2026_05; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals ATTACH PARTITION public.vendor_signals_2026_05 FOR VALUES FROM ('2026-05-01 00:00:00+00') TO ('2026-06-01 00:00:00+00');


--
-- Name: vendor_signals_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals ATTACH PARTITION public.vendor_signals_default DEFAULT;


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_log_entries audit_log_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log_entries
    ADD CONSTRAINT audit_log_entries_pkey PRIMARY KEY (id);


--
-- Name: ingestion_runs ingestion_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestion_runs
    ADD CONSTRAINT ingestion_runs_pkey PRIMARY KEY (id);


--
-- Name: ingestion_sources ingestion_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestion_sources
    ADD CONSTRAINT ingestion_sources_pkey PRIMARY KEY (id);


--
-- Name: risk_alerts risk_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_alerts
    ADD CONSTRAINT risk_alerts_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: scoring_rules scoring_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scoring_rules
    ADD CONSTRAINT scoring_rules_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: signal_definitions signal_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.signal_definitions
    ADD CONSTRAINT signal_definitions_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vendor_aliases vendor_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_aliases
    ADD CONSTRAINT vendor_aliases_pkey PRIMARY KEY (id);


--
-- Name: vendor_reports vendor_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_reports
    ADD CONSTRAINT vendor_reports_pkey PRIMARY KEY (id);


--
-- Name: vendor_scores vendor_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_scores
    ADD CONSTRAINT vendor_scores_pkey PRIMARY KEY (id);


--
-- Name: vendor_signals vendor_signals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals
    ADD CONSTRAINT vendor_signals_pkey PRIMARY KEY (id, recorded_at);


--
-- Name: vendor_signals_2026_04 vendor_signals_2026_04_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals_2026_04
    ADD CONSTRAINT vendor_signals_2026_04_pkey PRIMARY KEY (id, recorded_at);


--
-- Name: vendor_signals_2026_05 vendor_signals_2026_05_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals_2026_05
    ADD CONSTRAINT vendor_signals_2026_05_pkey PRIMARY KEY (id, recorded_at);


--
-- Name: vendor_signals_default vendor_signals_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_signals_default
    ADD CONSTRAINT vendor_signals_default_pkey PRIMARY KEY (id, recorded_at);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: audit_log_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_occurred_idx ON public.audit_log_entries USING btree (occurred_at DESC);


--
-- Name: audit_log_tenant_action_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_tenant_action_idx ON public.audit_log_entries USING btree (tenant_id, action, occurred_at DESC);


--
-- Name: audit_log_tenant_entity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_tenant_entity_idx ON public.audit_log_entries USING btree (tenant_id, entity_type, entity_id, occurred_at DESC);


--
-- Name: audit_log_tenant_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_tenant_occurred_idx ON public.audit_log_entries USING btree (tenant_id, occurred_at DESC);


--
-- Name: index_ingestion_runs_on_ingestion_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestion_runs_on_ingestion_source_id ON public.ingestion_runs USING btree (ingestion_source_id);


--
-- Name: index_ingestion_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestion_runs_on_tenant_id ON public.ingestion_runs USING btree (tenant_id);


--
-- Name: index_ingestion_sources_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ingestion_sources_on_tenant_id ON public.ingestion_sources USING btree (tenant_id);


--
-- Name: index_risk_alerts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_risk_alerts_on_tenant_id ON public.risk_alerts USING btree (tenant_id);


--
-- Name: index_risk_alerts_on_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_risk_alerts_on_vendor_id ON public.risk_alerts USING btree (vendor_id);


--
-- Name: index_scoring_rules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scoring_rules_on_tenant_id ON public.scoring_rules USING btree (tenant_id);


--
-- Name: index_scoring_rules_on_tenant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scoring_rules_on_tenant_id_and_created_at ON public.scoring_rules USING btree (tenant_id, created_at);


--
-- Name: index_sessions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_tenant_id ON public.sessions USING btree (tenant_id);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_signal_definitions_on_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_signal_definitions_on_category ON public.signal_definitions USING btree (category);


--
-- Name: index_signal_definitions_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_signal_definitions_on_code ON public.signal_definitions USING btree (code);


--
-- Name: index_signal_definitions_on_source_system; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_signal_definitions_on_source_system ON public.signal_definitions USING btree (source_system);


--
-- Name: index_tenants_on_api_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_api_key_hash ON public.tenants USING btree (api_key_hash);


--
-- Name: index_tenants_on_api_key_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_api_key_prefix ON public.tenants USING btree (api_key_prefix);


--
-- Name: index_tenants_on_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tenants_on_is_active ON public.tenants USING btree (is_active);


--
-- Name: index_tenants_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_slug ON public.tenants USING btree (slug);


--
-- Name: index_users_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_tenant_id ON public.users USING btree (tenant_id);


--
-- Name: index_users_on_tenant_id_and_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_tenant_id_and_email_address ON public.users USING btree (tenant_id, email_address);


--
-- Name: index_vendor_aliases_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_aliases_on_tenant_id ON public.vendor_aliases USING btree (tenant_id);


--
-- Name: index_vendor_aliases_on_tenant_id_and_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_aliases_on_tenant_id_and_vendor_id ON public.vendor_aliases USING btree (tenant_id, vendor_id);


--
-- Name: index_vendor_aliases_on_tenant_system_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vendor_aliases_on_tenant_system_ref ON public.vendor_aliases USING btree (tenant_id, source_system, source_ref);


--
-- Name: index_vendor_aliases_on_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_aliases_on_vendor_id ON public.vendor_aliases USING btree (vendor_id);


--
-- Name: index_vendor_aliases_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_aliases_pending ON public.vendor_aliases USING btree (tenant_id, is_confirmed) WHERE (is_confirmed = false);


--
-- Name: index_vendor_reports_on_requested_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_reports_on_requested_by_user_id ON public.vendor_reports USING btree (requested_by_user_id);


--
-- Name: index_vendor_reports_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_reports_on_tenant_id ON public.vendor_reports USING btree (tenant_id);


--
-- Name: index_vendor_reports_on_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_reports_on_vendor_id ON public.vendor_reports USING btree (vendor_id);


--
-- Name: index_vendor_scores_on_scoring_rules_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_scoring_rules_id ON public.vendor_scores USING btree (scoring_rules_id);


--
-- Name: index_vendor_scores_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_tenant_id ON public.vendor_scores USING btree (tenant_id);


--
-- Name: index_vendor_scores_on_tenant_id_and_band_and_computed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_tenant_id_and_band_and_computed_at ON public.vendor_scores USING btree (tenant_id, band, computed_at DESC);


--
-- Name: index_vendor_scores_on_tenant_id_and_computed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_tenant_id_and_computed_at ON public.vendor_scores USING btree (tenant_id, computed_at DESC);


--
-- Name: index_vendor_scores_on_tenant_id_and_vendor_id_and_computed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_tenant_id_and_vendor_id_and_computed_at ON public.vendor_scores USING btree (tenant_id, vendor_id, computed_at DESC);


--
-- Name: index_vendor_scores_on_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_scores_on_vendor_id ON public.vendor_scores USING btree (vendor_id);


--
-- Name: index_vendors_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendors_on_tenant_id ON public.vendors USING btree (tenant_id);


--
-- Name: index_vendors_on_tenant_id_and_category_where_present; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendors_on_tenant_id_and_category_where_present ON public.vendors USING btree (tenant_id, category) WHERE (category IS NOT NULL);


--
-- Name: index_vendors_on_tenant_id_and_normalized_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendors_on_tenant_id_and_normalized_name ON public.vendors USING btree (tenant_id, normalized_name);


--
-- Name: index_vendors_on_tenant_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendors_on_tenant_id_and_status ON public.vendors USING btree (tenant_id, status);


--
-- Name: index_vendors_on_tenant_id_and_tax_id_where_present; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vendors_on_tenant_id_and_tax_id_where_present ON public.vendors USING btree (tenant_id, tax_id) WHERE (tax_id IS NOT NULL);


--
-- Name: ingestion_runs_tenant_source_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ingestion_runs_tenant_source_started_idx ON public.ingestion_runs USING btree (tenant_id, ingestion_source_id, started_at DESC);


--
-- Name: ingestion_runs_tenant_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ingestion_runs_tenant_status_idx ON public.ingestion_runs USING btree (tenant_id, status);


--
-- Name: ingestion_sources_tenant_enabled_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ingestion_sources_tenant_enabled_idx ON public.ingestion_sources USING btree (tenant_id, is_enabled);


--
-- Name: ingestion_sources_tenant_system_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ingestion_sources_tenant_system_uidx ON public.ingestion_sources USING btree (tenant_id, source_system);


--
-- Name: risk_alerts_idempotency_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX risk_alerts_idempotency_uidx ON public.risk_alerts USING btree (tenant_id, vendor_id, triggered_by_score);


--
-- Name: risk_alerts_tenant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX risk_alerts_tenant_created_idx ON public.risk_alerts USING btree (tenant_id, created_at DESC);


--
-- Name: risk_alerts_tenant_new_band_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX risk_alerts_tenant_new_band_idx ON public.risk_alerts USING btree (tenant_id, new_band, created_at DESC);


--
-- Name: risk_alerts_tenant_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX risk_alerts_tenant_status_idx ON public.risk_alerts USING btree (tenant_id, status, created_at DESC);


--
-- Name: risk_alerts_tenant_vendor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX risk_alerts_tenant_vendor_idx ON public.risk_alerts USING btree (tenant_id, vendor_id, created_at DESC);


--
-- Name: scoring_rules_tenant_active_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scoring_rules_tenant_active_uidx ON public.scoring_rules USING btree (tenant_id) WHERE (is_active = true);


--
-- Name: vendor_reports_tenant_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_reports_tenant_created_idx ON public.vendor_reports USING btree (tenant_id, created_at DESC);


--
-- Name: vendor_reports_tenant_expires_ready_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_reports_tenant_expires_ready_idx ON public.vendor_reports USING btree (tenant_id, expires_at) WHERE (status = 'ready'::text);


--
-- Name: vendor_reports_tenant_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_reports_tenant_status_idx ON public.vendor_reports USING btree (tenant_id, status);


--
-- Name: vendor_reports_tenant_vendor_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_reports_tenant_vendor_type_idx ON public.vendor_reports USING btree (tenant_id, vendor_id, report_type, created_at DESC);


--
-- Name: vendor_signals_tenant_signal_code_recorded_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_tenant_signal_code_recorded_idx ON ONLY public.vendor_signals USING btree (tenant_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_2026_04_tenant_id_signal_code_recorded_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_04_tenant_id_signal_code_recorded_at_idx ON public.vendor_signals_2026_04 USING btree (tenant_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_dedup_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vendor_signals_dedup_uidx ON ONLY public.vendor_signals USING btree (tenant_id, source_system, source_event_id, recorded_at) WHERE (source_event_id IS NOT NULL);


--
-- Name: vendor_signals_2026_04_tenant_id_source_system_source_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vendor_signals_2026_04_tenant_id_source_system_source_event_idx ON public.vendor_signals_2026_04 USING btree (tenant_id, source_system, source_event_id, recorded_at) WHERE (source_event_id IS NOT NULL);


--
-- Name: vendor_signals_tenant_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_tenant_status_idx ON ONLY public.vendor_signals USING btree (tenant_id, status);


--
-- Name: vendor_signals_2026_04_tenant_id_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_04_tenant_id_status_idx ON public.vendor_signals_2026_04 USING btree (tenant_id, status);


--
-- Name: vendor_signals_tenant_vendor_code_recorded_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_tenant_vendor_code_recorded_idx ON ONLY public.vendor_signals USING btree (tenant_id, vendor_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_2026_04_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_04_tenant_id_vendor_id_signal_code_reco_idx ON public.vendor_signals_2026_04 USING btree (tenant_id, vendor_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_2026_05_tenant_id_signal_code_recorded_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_05_tenant_id_signal_code_recorded_at_idx ON public.vendor_signals_2026_05 USING btree (tenant_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_2026_05_tenant_id_source_system_source_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vendor_signals_2026_05_tenant_id_source_system_source_event_idx ON public.vendor_signals_2026_05 USING btree (tenant_id, source_system, source_event_id, recorded_at) WHERE (source_event_id IS NOT NULL);


--
-- Name: vendor_signals_2026_05_tenant_id_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_05_tenant_id_status_idx ON public.vendor_signals_2026_05 USING btree (tenant_id, status);


--
-- Name: vendor_signals_2026_05_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_2026_05_tenant_id_vendor_id_signal_code_reco_idx ON public.vendor_signals_2026_05 USING btree (tenant_id, vendor_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_default_tenant_id_signal_code_recorded_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_default_tenant_id_signal_code_recorded_at_idx ON public.vendor_signals_default USING btree (tenant_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_default_tenant_id_source_system_source_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vendor_signals_default_tenant_id_source_system_source_event_idx ON public.vendor_signals_default USING btree (tenant_id, source_system, source_event_id, recorded_at) WHERE (source_event_id IS NOT NULL);


--
-- Name: vendor_signals_default_tenant_id_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_default_tenant_id_status_idx ON public.vendor_signals_default USING btree (tenant_id, status);


--
-- Name: vendor_signals_default_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vendor_signals_default_tenant_id_vendor_id_signal_code_reco_idx ON public.vendor_signals_default USING btree (tenant_id, vendor_id, signal_code, recorded_at DESC);


--
-- Name: vendor_signals_2026_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_pkey ATTACH PARTITION public.vendor_signals_2026_04_pkey;


--
-- Name: vendor_signals_2026_04_tenant_id_signal_code_recorded_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_signal_code_recorded_idx ATTACH PARTITION public.vendor_signals_2026_04_tenant_id_signal_code_recorded_at_idx;


--
-- Name: vendor_signals_2026_04_tenant_id_source_system_source_event_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_dedup_uidx ATTACH PARTITION public.vendor_signals_2026_04_tenant_id_source_system_source_event_idx;


--
-- Name: vendor_signals_2026_04_tenant_id_status_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_status_idx ATTACH PARTITION public.vendor_signals_2026_04_tenant_id_status_idx;


--
-- Name: vendor_signals_2026_04_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_vendor_code_recorded_idx ATTACH PARTITION public.vendor_signals_2026_04_tenant_id_vendor_id_signal_code_reco_idx;


--
-- Name: vendor_signals_2026_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_pkey ATTACH PARTITION public.vendor_signals_2026_05_pkey;


--
-- Name: vendor_signals_2026_05_tenant_id_signal_code_recorded_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_signal_code_recorded_idx ATTACH PARTITION public.vendor_signals_2026_05_tenant_id_signal_code_recorded_at_idx;


--
-- Name: vendor_signals_2026_05_tenant_id_source_system_source_event_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_dedup_uidx ATTACH PARTITION public.vendor_signals_2026_05_tenant_id_source_system_source_event_idx;


--
-- Name: vendor_signals_2026_05_tenant_id_status_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_status_idx ATTACH PARTITION public.vendor_signals_2026_05_tenant_id_status_idx;


--
-- Name: vendor_signals_2026_05_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_vendor_code_recorded_idx ATTACH PARTITION public.vendor_signals_2026_05_tenant_id_vendor_id_signal_code_reco_idx;


--
-- Name: vendor_signals_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_pkey ATTACH PARTITION public.vendor_signals_default_pkey;


--
-- Name: vendor_signals_default_tenant_id_signal_code_recorded_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_signal_code_recorded_idx ATTACH PARTITION public.vendor_signals_default_tenant_id_signal_code_recorded_at_idx;


--
-- Name: vendor_signals_default_tenant_id_source_system_source_event_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_dedup_uidx ATTACH PARTITION public.vendor_signals_default_tenant_id_source_system_source_event_idx;


--
-- Name: vendor_signals_default_tenant_id_status_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_status_idx ATTACH PARTITION public.vendor_signals_default_tenant_id_status_idx;


--
-- Name: vendor_signals_default_tenant_id_vendor_id_signal_code_reco_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.vendor_signals_tenant_vendor_code_recorded_idx ATTACH PARTITION public.vendor_signals_default_tenant_id_vendor_id_signal_code_reco_idx;


--
-- Name: vendor_signals vendor_signals_append_only_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER vendor_signals_append_only_trg BEFORE DELETE OR UPDATE ON public.vendor_signals FOR EACH ROW EXECUTE FUNCTION public.vendor_signals_enforce_append_only();


--
-- Name: vendor_reports fk_rails_0fccc03910; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_reports
    ADD CONSTRAINT fk_rails_0fccc03910 FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id);


--
-- Name: vendor_reports fk_rails_1006bb2694; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_reports
    ADD CONSTRAINT fk_rails_1006bb2694 FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: users fk_rails_135c8f54b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_135c8f54b2 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: scoring_rules fk_rails_339f34b65a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scoring_rules
    ADD CONSTRAINT fk_rails_339f34b65a FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: vendors fk_rails_39179871c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT fk_rails_39179871c3 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: sessions fk_rails_4cc5d929b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_4cc5d929b0 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ingestion_sources fk_rails_4ea4231a83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestion_sources
    ADD CONSTRAINT fk_rails_4ea4231a83 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: vendor_aliases fk_rails_580b83a8a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_aliases
    ADD CONSTRAINT fk_rails_580b83a8a8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: risk_alerts fk_rails_5baec055b3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_alerts
    ADD CONSTRAINT fk_rails_5baec055b3 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ingestion_runs fk_rails_5f3a4215e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestion_runs
    ADD CONSTRAINT fk_rails_5f3a4215e5 FOREIGN KEY (ingestion_source_id) REFERENCES public.ingestion_sources(id);


--
-- Name: ingestion_runs fk_rails_676b94fa15; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingestion_runs
    ADD CONSTRAINT fk_rails_676b94fa15 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: vendor_scores fk_rails_70c7d50989; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_scores
    ADD CONSTRAINT fk_rails_70c7d50989 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: vendor_scores fk_rails_73e4d4806c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_scores
    ADD CONSTRAINT fk_rails_73e4d4806c FOREIGN KEY (scoring_rules_id) REFERENCES public.scoring_rules(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: vendor_scores fk_rails_77441f4fa7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_scores
    ADD CONSTRAINT fk_rails_77441f4fa7 FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: risk_alerts fk_rails_86e2437ad1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_alerts
    ADD CONSTRAINT fk_rails_86e2437ad1 FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: vendor_aliases fk_rails_a380566a8d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_aliases
    ADD CONSTRAINT fk_rails_a380566a8d FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE CASCADE;


--
-- Name: vendor_reports fk_rails_b1c1e10ec4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_reports
    ADD CONSTRAINT fk_rails_b1c1e10ec4 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: risk_alerts risk_alerts_triggered_by_score_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.risk_alerts
    ADD CONSTRAINT risk_alerts_triggered_by_score_fk FOREIGN KEY (triggered_by_score) REFERENCES public.vendor_scores(id) ON DELETE RESTRICT;


--
-- Name: vendor_signals vendor_signals_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.vendor_signals
    ADD CONSTRAINT vendor_signals_tenant_fk FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: vendor_signals vendor_signals_vendor_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.vendor_signals
    ADD CONSTRAINT vendor_signals_vendor_fk FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260426100100'),
('20260426100000'),
('20260425134117'),
('20260424200100'),
('20260424200000'),
('20260424190000'),
('20260424180000'),
('20260424170200'),
('20260424170100'),
('20260424170000'),
('20260424160100'),
('20260424160000'),
('20260424150300'),
('20260424150200'),
('20260424150100'),
('20260424150000'),
('20260424132405'),
('20260424132355');

