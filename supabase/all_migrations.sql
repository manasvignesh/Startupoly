-- Migration 0001: Core relational schema, types, indexes, and helper functions
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Custom Types
CREATE TYPE public.room_status AS ENUM (
  'CREATED',
  'LOBBY',
  'ACTIVE',
  'TIME_EXPIRED',
  'FINALIZED'
);

-- 2. Admins Table (created before is_admin() function)
CREATE TABLE public.admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE
);
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- 3. Helper Functions
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.admins WHERE user_id = auth.uid()
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.app_now()
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  test_now text;
  app_env text;
BEGIN
  test_now := current_setting('app.test_now', true);
  app_env := current_setting('app.env', true);
  IF test_now IS NOT NULL AND test_now <> '' AND app_env = 'test' THEN
    RETURN test_now::timestamptz;
  END IF;
  RETURN clock_timestamp();
END;
$$;

-- 4. Core Tables

-- Rooms Table
CREATE TABLE public.rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  status public.room_status NOT NULL DEFAULT 'CREATED',
  team_count smallint NOT NULL CHECK (team_count BETWEEN 5 AND 6),
  duration_seconds int NOT NULL DEFAULT 3000 CHECK (duration_seconds > 0),
  started_at timestamptz,
  ends_at timestamptz,
  finalized_at timestamptz,
  winner_team_id uuid,
  tiebreak_note text,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz DEFAULT now(),
  CHECK (ends_at IS NULL OR started_at IS NOT NULL)
);
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX idx_rooms_unique_active_code ON public.rooms (code) WHERE status <> 'FINALIZED';
CREATE UNIQUE INDEX idx_rooms_single_active ON public.rooms ((true)) WHERE status <> 'FINALIZED';

-- Teams Table
CREATE TABLE public.teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE RESTRICT,
  slot smallint NOT NULL CHECK (slot BETWEEN 1 AND 6),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 30),
  color text NOT NULL CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  cash integer NOT NULL DEFAULT 1000 CHECK (cash >= 0),
  cv integer NOT NULL DEFAULT 0 CHECK (cv >= 0),
  is_bankrupt boolean NOT NULL DEFAULT false,
  tiebreak_order smallint,
  version integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE (room_id, slot),
  UNIQUE (room_id, color),
  UNIQUE (id, room_id)
);
ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;

-- Add deferred circular foreign key for winner_team_id
ALTER TABLE public.rooms
  ADD CONSTRAINT fk_rooms_winner_team
  FOREIGN KEY (winner_team_id)
  REFERENCES public.teams(id);

-- Team Secrets Table (Admin only)
CREATE TABLE public.team_secrets (
  team_id uuid PRIMARY KEY REFERENCES public.teams(id) ON DELETE CASCADE,
  join_pin text NOT NULL CHECK (join_pin ~ '^[0-9]{4}$')
);
ALTER TABLE public.team_secrets ENABLE ROW LEVEL SECURITY;

-- Team Claims Table (Anonymous phone sessions linked to team)
CREATE TABLE public.team_claims (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  team_id uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  claimed_at timestamptz DEFAULT now(),
  PRIMARY KEY (user_id, team_id)
);
ALTER TABLE public.team_claims ENABLE ROW LEVEL SECURITY;

-- Join Attempts Table (Throttling / Audit)
CREATE TABLE public.join_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid,
  team_id uuid,
  success boolean,
  attempted_at timestamptz DEFAULT now()
);
ALTER TABLE public.join_attempts ENABLE ROW LEVEL SECURITY;

-- Business Catalog Table
CREATE TABLE public.business_catalog (
  key text PRIMARY KEY,
  name text NOT NULL,
  cost int NOT NULL,
  initial_cv int NOT NULL,
  u1_cost int NOT NULL,
  u2_cost int NOT NULL,
  u1_cv int NOT NULL DEFAULT 300,
  u2_cv int NOT NULL DEFAULT 400,
  is_provisional boolean NOT NULL DEFAULT false,
  sort_order smallint NOT NULL
);
ALTER TABLE public.business_catalog ENABLE ROW LEVEL SECURITY;

-- Team Businesses Table
CREATE TABLE public.team_businesses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL,
  team_id uuid NOT NULL,
  business_key text NOT NULL REFERENCES public.business_catalog(key),
  level smallint NOT NULL DEFAULT 0 CHECK (level BETWEEN 0 AND 2),
  acquired_at timestamptz DEFAULT now(),
  UNIQUE (room_id, business_key),
  FOREIGN KEY (team_id, room_id) REFERENCES public.teams(id, room_id) ON DELETE CASCADE
);
ALTER TABLE public.team_businesses ENABLE ROW LEVEL SECURITY;

-- Activity Events Table (Append-only Audit Log)
CREATE TABLE public.activity_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_id uuid NOT NULL REFERENCES public.rooms(id),
  team_id uuid REFERENCES public.teams(id),
  group_id uuid,
  request_id uuid UNIQUE,
  type text NOT NULL CHECK (type IN (
    'ROOM_CREATED',
    'TEAM_CONFIGURED',
    'LOBBY_OPENED',
    'TEAM_CLAIMED',
    'TEAM_RELEASED',
    'GAME_STARTED',
    'CASH_SET',
    'CV_SET',
    'ADJUSTMENT',
    'BUSINESS_ADDED',
    'BUSINESS_LEVEL_SET',
    'BUSINESS_REMOVED',
    'BANKRUPTCY_SET',
    'TIEBREAK_SET',
    'TIME_EXPIRED',
    'GAME_FINALIZED',
    'GAME_ABORTED'
  )),
  business_key text,
  prev jsonb,
  new jsonb,
  note text,
  is_correction boolean NOT NULL DEFAULT false,
  actor_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.activity_events ENABLE ROW LEVEL SECURITY;

-- Final Results Table (Immutable after finalization)
CREATE TABLE public.final_results (
  room_id uuid NOT NULL REFERENCES public.rooms(id),
  team_id uuid NOT NULL REFERENCES public.teams(id),
  rank smallint NOT NULL,
  cv int NOT NULL,
  cash int NOT NULL,
  business_count smallint NOT NULL,
  is_bankrupt boolean NOT NULL,
  PRIMARY KEY (room_id, team_id)
);
ALTER TABLE public.final_results ENABLE ROW LEVEL SECURITY;

-- Indexes for high-frequency queries, RLS filtering, and Realtime
CREATE INDEX idx_teams_room_id ON public.teams(room_id);
CREATE INDEX idx_team_businesses_team_id ON public.team_businesses(team_id);
CREATE INDEX idx_activity_events_room_id_id ON public.activity_events(room_id, id DESC);
CREATE INDEX idx_activity_events_room_team ON public.activity_events(room_id, team_id);
CREATE INDEX idx_team_claims_team_id ON public.team_claims(team_id);


-- Migration 0002: Integrity triggers and lifecycle constraints
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Max 3 businesses per team constraint trigger
CREATE OR REPLACE FUNCTION public.fn_check_business_cap()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (SELECT count(*) FROM public.team_businesses WHERE team_id = NEW.team_id) >= 3 THEN
    RAISE EXCEPTION 'BUSINESS_CAP';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_business_cap
BEFORE INSERT ON public.team_businesses
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_business_cap();

-- 2. Room immutability triggers (teams, team_businesses, rooms)
-- Disallow modifications to teams in a FINALIZED room
CREATE OR REPLACE FUNCTION public.fn_check_team_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  r_status public.room_status;
  target_room_id uuid;
BEGIN
  target_room_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.room_id ELSE NEW.room_id END;
  SELECT status INTO r_status FROM public.rooms WHERE id = target_room_id;
  IF r_status = 'FINALIZED' THEN
    RAISE EXCEPTION 'ROOM_FINALIZED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_teams_immutable
BEFORE INSERT OR UPDATE OR DELETE ON public.teams
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_team_room_immutable();

-- Disallow modifications to team_businesses in a FINALIZED room
CREATE OR REPLACE FUNCTION public.fn_check_team_business_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  r_status public.room_status;
  target_room_id uuid;
BEGIN
  target_room_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.room_id ELSE NEW.room_id END;
  SELECT status INTO r_status FROM public.rooms WHERE id = target_room_id;
  IF r_status = 'FINALIZED' THEN
    RAISE EXCEPTION 'ROOM_FINALIZED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_team_businesses_immutable
BEFORE INSERT OR UPDATE OR DELETE ON public.team_businesses
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_team_business_room_immutable();

-- Disallow update/delete on rooms once FINALIZED (allows the single update that sets status to FINALIZED)
CREATE OR REPLACE FUNCTION public.fn_check_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status = 'FINALIZED' THEN
    RAISE EXCEPTION 'ROOM_FINALIZED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_rooms_immutable
BEFORE UPDATE OR DELETE ON public.rooms
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_room_immutable();

-- 3. Room status transition trigger (forward-only progression)
CREATE OR REPLACE FUNCTION public.fn_check_room_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    IF NOT (
      (OLD.status = 'CREATED' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'LOBBY' AND NEW.status = 'ACTIVE') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'TIME_EXPIRED') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'FINALIZED')
    ) THEN
      RAISE EXCEPTION 'INVALID_TRANSITION';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rooms_status_transition
BEFORE UPDATE ON public.rooms
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_room_status_transition();

-- 4. Audit and Results immutability (activity_events & final_results are append-only)
CREATE OR REPLACE FUNCTION public.fn_check_immutable_table()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE';
END;
$$;

CREATE TRIGGER trg_activity_events_immutable
BEFORE UPDATE OR DELETE ON public.activity_events
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_immutable_table();

CREATE TRIGGER trg_final_results_immutable
BEFORE UPDATE OR DELETE ON public.final_results
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_immutable_table();


-- Migration 0003: Row Level Security policies and role privileges
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Revoke default privileges and grant schema usage
GRANT USAGE ON SCHEMA public TO anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL ROUTINES IN SCHEMA public FROM anon, authenticated;

-- Grant EXECUTE on public helpers
GRANT EXECUTE ON FUNCTION public.is_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.app_now() TO anon, authenticated;

-- Grant SELECT ONLY where explicit policies allow reading
GRANT SELECT ON public.admins TO authenticated;
GRANT SELECT ON public.rooms TO anon, authenticated;
GRANT SELECT ON public.teams TO anon, authenticated;
GRANT SELECT ON public.team_secrets TO authenticated;
GRANT SELECT ON public.team_claims TO anon, authenticated;
GRANT SELECT ON public.business_catalog TO anon, authenticated;
GRANT SELECT ON public.team_businesses TO anon, authenticated;
GRANT SELECT ON public.activity_events TO authenticated;
GRANT SELECT ON public.final_results TO anon, authenticated;

-- NO INSERT / UPDATE / DELETE privileges granted to anon or authenticated.
-- All mutations in subsequent phases run through SECURITY DEFINER RPCs.

-- 2. RLS Policies

-- Admins Table
CREATE POLICY "Admins can select own row"
  ON public.admins
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Rooms Table
CREATE POLICY "Admins can select all rooms"
  ON public.rooms
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Claimed users can select their room"
  ON public.rooms
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.teams t
      JOIN public.team_claims tc ON t.id = tc.team_id
      WHERE t.room_id = public.rooms.id
        AND tc.user_id = (SELECT auth.uid())
    )
  );

-- Teams Table
CREATE POLICY "Admins can select all teams"
  ON public.teams
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Claimed users can select their own team"
  ON public.teams
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_claims tc
      WHERE tc.team_id = public.teams.id
        AND tc.user_id = (SELECT auth.uid())
    )
  );

-- Team Secrets Table (Admin Only)
CREATE POLICY "Admins can select team secrets"
  ON public.team_secrets
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- Team Claims Table
CREATE POLICY "Admins can select all team claims"
  ON public.team_claims
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Users can select own team claims"
  ON public.team_claims
  FOR SELECT
  TO anon, authenticated
  USING (user_id = (SELECT auth.uid()));

-- Join Attempts Table
-- No policies defined; completely unreadable by client roles.

-- Business Catalog Table
CREATE POLICY "Public read business catalog"
  ON public.business_catalog
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- Team Businesses Table
CREATE POLICY "Admins can select all team businesses"
  ON public.team_businesses
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Claimed users can select own team businesses"
  ON public.team_businesses
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_claims tc
      WHERE tc.team_id = public.team_businesses.team_id
        AND tc.user_id = (SELECT auth.uid())
    )
  );

-- Activity Events Table (Admin Only)
CREATE POLICY "Admins can select all activity events"
  ON public.activity_events
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- Final Results Table
CREATE POLICY "Admins can select all final results"
  ON public.final_results
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Claimed users can select final results when room is finalized"
  ON public.final_results
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.teams t
      JOIN public.team_claims tc ON t.id = tc.team_id
      WHERE t.room_id = public.final_results.room_id
        AND tc.user_id = (SELECT auth.uid())
    )
    AND EXISTS (
      SELECT 1 FROM public.rooms r
      WHERE r.id = public.final_results.room_id
        AND r.status = 'FINALIZED'
    )
  );


-- Migration 0004: Official Rulebook Business Catalog Seed
-- STARTUPOLY Live Scoreboard & Game Management System

INSERT INTO public.business_catalog (
  key,
  name,
  cost,
  initial_cv,
  u1_cost,
  u2_cost,
  u1_cv,
  u2_cv,
  is_provisional,
  sort_order
) VALUES
  ('edtech', 'EdTech', 200, 150, 150, 200, 300, 400, false, 1),
  ('saas', 'SaaS', 300, 180, 200, 250, 300, 400, false, 2),
  ('ecommerce', 'E-Commerce', 300, 180, 200, 250, 300, 400, false, 3),
  ('fintech', 'FinTech', 400, 200, 250, 300, 300, 400, false, 4),
  ('healthtech', 'HealthTech', 400, 200, 250, 300, 300, 400, false, 5),
  ('ai_deeptech', 'AI / DeepTech', 500, 250, 300, 350, 300, 400, false, 6),
  ('devtools', 'DevTools / Infrastructure', 300, 190, 200, 250, 300, 400, true, 7),
  ('cybersecurity', 'Cybersecurity', 400, 220, 250, 300, 300, 400, true, 8),
  ('cleantech', 'CleanTech / Energy', 500, 240, 300, 350, 300, 400, true, 9),
  ('robotics', 'Robotics & IoT', 500, 250, 300, 350, 300, 400, true, 10)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  cost = EXCLUDED.cost,
  initial_cv = EXCLUDED.initial_cv,
  u1_cost = EXCLUDED.u1_cost,
  u2_cost = EXCLUDED.u2_cost,
  u1_cv = EXCLUDED.u1_cv,
  u2_cv = EXCLUDED.u2_cv,
  is_provisional = EXCLUDED.is_provisional,
  sort_order = EXCLUDED.sort_order;


-- Migration 0005: Supabase Realtime publication setup
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Ensure tables are added to supabase_realtime publication idempotently
DO $$
BEGIN
  -- rooms
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'rooms'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.rooms;
  END IF;

  -- teams
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'teams'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.teams;
  END IF;

  -- team_businesses
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'team_businesses'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.team_businesses;
  END IF;

  -- activity_events
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'activity_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.activity_events;
  END IF;
END $$;

-- 2. Set REPLICA IDENTITY FULL on team_businesses so DELETE events broadcast full old row (including team_id)
ALTER TABLE public.team_businesses REPLICA IDENTITY FULL;


-- HISTORICAL MIGRATION: this drops the legacy tables of the pre-0001 schema. It has already been applied and
-- must never be re-run against production data (comment-only edit; the SQL below is unchanged).
-- Migration 0006: Drop legacy prototype tables
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- CAUTION: DESTRUCTIVE MIGRATION
-- This migration permanently drops the legacy prototype tables `matches` and `match_events`.
-- It must only be run after the project owner has confirmed that no old JSON-blob match data
-- or event logs are needed.

DROP TABLE IF EXISTS public.match_events CASCADE;
DROP TABLE IF EXISTS public.matches CASCADE;


-- Migration 0007: Core Functions (Error Helper, Server Clock, Expiry Derivation)
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Standardized Error Raising Helper
CREATE OR REPLACE FUNCTION public.raise_error(
  err_code text,
  detail jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION '%', err_code USING DETAIL = detail::text;
END;
$$;

-- 2. Server Clock Function
CREATE OR REPLACE FUNCTION public.server_time()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.app_now();
$$;

REVOKE ALL ON FUNCTION public.server_time() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.server_time() TO anon, authenticated;

-- 3. Idempotent Expiry Derivation Function
CREATE OR REPLACE FUNCTION public.expire_if_due(p_room_id uuid)
RETURNS public.room_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_ends_at timestamptz;
BEGIN
  SELECT status, ends_at INTO v_status, v_ends_at
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status = 'ACTIVE' AND v_ends_at IS NOT NULL AND public.app_now() >= v_ends_at THEN
    UPDATE public.rooms
    SET status = 'TIME_EXPIRED'
    WHERE id = p_room_id;

    INSERT INTO public.activity_events (
      room_id,
      type,
      note,
      created_at
    ) VALUES (
      p_room_id,
      'TIME_EXPIRED',
      'Gameplay window expired. Scores frozen.',
      public.app_now()
    );

    v_status := 'TIME_EXPIRED';
  END IF;

  RETURN v_status;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_if_due(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.expire_if_due(uuid) TO anon, authenticated;


-- Migration 0008: Admin Stored Procedures
-- STARTUPOLY Live Scoreboard & Game Management System

-- Helper: Get Team Snapshot
CREATE OR REPLACE FUNCTION public.get_team_snapshot(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_team jsonb;
  v_businesses jsonb;
BEGIN
  SELECT to_jsonb(t.*) INTO v_team
  FROM public.teams t
  WHERE t.id = p_team_id;

  IF v_team IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost,
      'initial_cv', bc.initial_cv,
      'cv_contribution', bc.initial_cv + (CASE WHEN tb.level >= 1 THEN bc.u1_cv ELSE 0 END) + (CASE WHEN tb.level >= 2 THEN bc.u2_cv ELSE 0 END)
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = p_team_id;

  RETURN jsonb_build_object('team', v_team, 'businesses', v_businesses);
END;
$$;

-- 1. admin_create_room(team_count int, teams jsonb)
CREATE OR REPLACE FUNCTION public.admin_create_room(
  team_count int,
  teams jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_code text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_team_id uuid;
  v_team_elem jsonb;
  v_name text;
  v_color text;
  v_pin text;
  i int;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF EXISTS (SELECT 1 FROM public.rooms WHERE status <> 'FINALIZED') THEN
    PERFORM public.raise_error('NON_FINAL_ROOM_EXISTS');
  END IF;

  IF team_count NOT BETWEEN 5 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('team_count', team_count));
  END IF;

  IF jsonb_array_length(teams) <> team_count THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('teams_length', jsonb_array_length(teams)));
  END IF;

  -- Generate unique 6-character room code
  LOOP
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, floor(random() * 32)::int + 1, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.rooms WHERE code = v_code AND status <> 'FINALIZED');
  END LOOP;

  INSERT INTO public.rooms (code, status, team_count, created_by, created_at)
  VALUES (v_code, 'CREATED', team_count, auth.uid(), public.app_now())
  RETURNING id INTO v_room_id;

  -- Insert teams & unique PINs
  FOR i IN 1..team_count LOOP
    v_team_elem := teams->(i - 1);
    v_name := trim(coalesce(v_team_elem->>'name', ''));
    v_color := upper(trim(coalesce(v_team_elem->>'color', '')));

    IF char_length(v_name) < 1 OR char_length(v_name) > 30 OR v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('slot', i, 'name', v_name, 'color', v_color));
    END IF;

    -- Generate random 4-digit PIN unique within this room
    LOOP
      v_pin := lpad(floor(random() * 10000)::text, 4, '0');
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.team_secrets ts
        JOIN public.teams t ON ts.team_id = t.id
        WHERE t.room_id = v_room_id AND ts.join_pin = v_pin
      );
    END LOOP;

    INSERT INTO public.teams (room_id, slot, name, color, cash, cv, version, created_at)
    VALUES (v_room_id, i, v_name, v_color, 1000, 0, 0, public.app_now())
    RETURNING id INTO v_team_id;

    INSERT INTO public.team_secrets (team_id, join_pin)
    VALUES (v_team_id, v_pin);
  END LOOP;

  INSERT INTO public.activity_events (
    room_id,
    type,
    new,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    'ROOM_CREATED',
    jsonb_build_object('code', v_code, 'team_count', team_count),
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = v_room_id;
  RETURN v_room;
END;
$$;

-- 2. admin_update_team_config(team_id, name, color)
CREATE OR REPLACE FUNCTION public.admin_update_team_config(
  team_id uuid,
  name text,
  color text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_name text := trim(name);
  v_color text := upper(trim(color));
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id, r.status, to_jsonb(t.*)
  INTO v_room_id, v_status, v_prev
  FROM public.teams t
  JOIN public.rooms r ON t.room_id = r.id
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status NOT IN ('CREATED', 'LOBBY') THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF char_length(v_name) < 1 OR char_length(v_name) > 30 OR v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('name', v_name, 'color', v_color));
  END IF;

  UPDATE public.teams
  SET name = v_name, color = v_color
  WHERE id = team_id;

  v_new := jsonb_build_object('name', v_name, 'color', v_color);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    type,
    prev,
    new,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    'TEAM_CONFIGURED',
    v_prev,
    v_new,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 3. admin_open_lobby(room_id)
CREATE OR REPLACE FUNCTION public.admin_open_lobby(room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status <> 'CREATED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  UPDATE public.rooms
  SET status = 'LOBBY'
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    room_id,
    'LOBBY_OPENED',
    'Lobby opened for team connections',
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$$;

-- 4. admin_release_team(team_id)
CREATE OR REPLACE FUNCTION public.admin_release_team(team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id, r.status INTO v_room_id, v_status
  FROM public.teams t
  JOIN public.rooms r ON t.room_id = r.id
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id;

  IF v_status NOT IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED') THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  DELETE FROM public.team_claims WHERE team_claims.team_id = admin_release_team.team_id;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    'TEAM_RELEASED',
    'Team slot released by admin',
    auth.uid(),
    public.app_now()
  );

  RETURN jsonb_build_object('team_id', team_id, 'released', true);
END;
$$;

-- 5. admin_start_game(room_id, force)
CREATE OR REPLACE FUNCTION public.admin_start_game(
  room_id uuid,
  force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_duration int;
  v_unclaimed_slots jsonb;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status, duration_seconds INTO v_status, v_duration
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status <> 'LOBBY' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'ACTIVE'));
  END IF;

  IF NOT force THEN
    SELECT jsonb_agg(t.slot ORDER BY t.slot) INTO v_unclaimed_slots
    FROM public.teams t
    WHERE t.room_id = admin_start_game.room_id
      AND NOT EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id);

    IF v_unclaimed_slots IS NOT NULL AND jsonb_array_length(v_unclaimed_slots) > 0 THEN
      PERFORM public.raise_error('TEAMS_NOT_JOINED', jsonb_build_object('unclaimed_slots', v_unclaimed_slots));
    END IF;
  END IF;

  v_started_at := public.app_now();
  v_ends_at := v_started_at + (v_duration || ' seconds')::interval;

  UPDATE public.rooms
  SET status = 'ACTIVE',
      started_at = v_started_at,
      ends_at = v_ends_at
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    room_id,
    'GAME_STARTED',
    'Gameplay started. 50:00 countdown active.',
    auth.uid(),
    v_started_at
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$$;

-- 6. admin_set_team_values(team_id, cash, cv, expected_version, request_id, note)
CREATE OR REPLACE FUNCTION public.admin_set_team_values(
  team_id uuid,
  cash int DEFAULT NULL,
  cv int DEFAULT NULL,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_version int;
  v_curr_cash int;
  v_curr_cv int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_team_values.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id INTO v_room_id
  FROM public.teams t
  WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);

  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  SELECT version, teams.cash, teams.cv
  INTO v_curr_version, v_curr_cash, v_curr_cv
  FROM public.teams
  WHERE id = team_id
  FOR UPDATE;

  IF v_curr_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_curr_version,
      'cash', v_curr_cash,
      'cv', v_curr_cv
    ));
  END IF;

  IF cash IS NOT NULL AND cash < 0 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('cash', cash));
  END IF;

  IF cv IS NOT NULL AND cv < 0 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('cv', cv));
  END IF;

  v_prev := jsonb_build_object('cash', v_curr_cash, 'cv', v_curr_cv);
  v_new := jsonb_build_object('cash', coalesce(cash, v_curr_cash), 'cv', coalesce(cv, v_curr_cv));

  UPDATE public.teams
  SET cash = coalesce(admin_set_team_values.cash, teams.cash),
      cv = coalesce(admin_set_team_values.cv, teams.cv),
      version = version + 1
  WHERE id = team_id;

  IF cash IS NOT NULL AND cash <> v_curr_cash THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, request_id, 'CASH_SET', jsonb_build_object('cash', v_curr_cash), jsonb_build_object('cash', cash), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  IF cv IS NOT NULL AND cv <> v_curr_cv THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, CASE WHEN cash IS NOT NULL AND cash <> v_curr_cash THEN NULL ELSE request_id END, 'CV_SET', jsonb_build_object('cv', v_curr_cv), jsonb_build_object('cv', cv), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 7. admin_adjust(changes, label, note, request_id)
CREATE OR REPLACE FUNCTION public.admin_adjust(
  changes jsonb,
  label text,
  note text DEFAULT NULL,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_correction boolean := false;
  v_group_id uuid := gen_random_uuid();
  v_item jsonb;
  v_team_id uuid;
  v_cash_delta int;
  v_cv_delta int;
  v_exp_ver int;
  v_curr_ver int;
  v_curr_cash int;
  v_curr_cv int;
  v_res_cash int;
  v_res_cv int;
  v_clamped boolean;
  v_first boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_adjust.request_id) THEN
    RETURN jsonb_build_object('status', 'idempotent_duplicate', 'request_id', request_id);
  END IF;

  -- Verify room status
  SELECT t.room_id INTO v_room_id
  FROM public.teams t
  WHERE t.id = (changes->0->>'team_id')::uuid;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);

  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  -- Phase 1 Validation: lock teams in ID order to prevent deadlocks
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);
    v_exp_ver := (v_item->>'expected_version')::int;

    SELECT version, cash, cv INTO v_curr_ver, v_curr_cash, v_curr_cv
    FROM public.teams
    WHERE id = v_team_id
    FOR UPDATE;

    IF v_curr_ver <> v_exp_ver THEN
      PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
        'team_id', v_team_id,
        'expected_version', v_exp_ver,
        'current_version', v_curr_ver
      ));
    END IF;

    v_res_cash := v_curr_cash + v_cash_delta;
    IF v_res_cash < 0 THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object(
        'team_id', v_team_id,
        'cash', v_curr_cash,
        'delta', v_cash_delta,
        'shortfall', abs(v_res_cash)
      ));
    END IF;
  END LOOP;

  -- Phase 2 Execution
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);

    SELECT cash, cv INTO v_curr_cash, v_curr_cv FROM public.teams WHERE id = v_team_id;

    v_res_cash := v_curr_cash + v_cash_delta;
    v_res_cv := v_curr_cv + v_cv_delta;
    v_clamped := false;

    IF v_res_cv < 0 THEN
      v_res_cv := 0;
      v_clamped := true;
    END IF;

    UPDATE public.teams
    SET cash = v_res_cash,
        cv = v_res_cv,
        version = version + 1
    WHERE id = v_team_id;

    INSERT INTO public.activity_events (
      room_id,
      team_id,
      group_id,
      request_id,
      type,
      prev,
      new,
      note,
      is_correction,
      actor_id,
      created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      v_group_id,
      CASE WHEN v_first THEN request_id ELSE NULL END,
      'ADJUSTMENT',
      jsonb_build_object('cash', v_curr_cash, 'cv', v_curr_cv),
      jsonb_build_object('cash', v_res_cash, 'cv', v_res_cv, 'cash_delta', v_cash_delta, 'cv_delta', v_cv_delta, 'clamped', v_clamped),
      coalesce(label || ': ', '') || coalesce(note, ''),
      v_is_correction,
      auth.uid(),
      public.app_now()
    );

    v_first := false;
    v_results := v_results || public.get_team_snapshot(v_team_id);
  END LOOP;

  RETURN v_results;
END;
$$;

-- 8. admin_add_business(team_id, business_key, apply_purchase, expected_version, request_id, note)
CREATE OR REPLACE FUNCTION public.admin_add_business(
  team_id uuid,
  business_key text,
  apply_purchase boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_cost int;
  v_initial_cv int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_add_business.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id, t.is_bankrupt, t.version, t.cash, t.cv
  INTO v_room_id, v_is_bankrupt, v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 3 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, initial_cv INTO v_cost, v_initial_cv
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key);

  IF apply_purchase THEN
    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
    v_cv := v_cv + v_initial_cv;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 9. admin_set_business_level(team_id, business_key, new_level, apply_upgrade, expected_version, request_id, note)
CREATE OR REPLACE FUNCTION public.admin_set_business_level(
  team_id uuid,
  business_key text,
  new_level smallint,
  apply_upgrade boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_curr_level smallint;
  v_cost int;
  v_cv_gain int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_business_level.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id, t.version, t.cash, t.cv
  INTO v_room_id, v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash, 'cv', v_cv);

  IF apply_upgrade THEN
    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost, u1_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost, u2_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
    v_cv := v_cv + v_cv_gain;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'cv', v_cv, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 10. admin_remove_business(team_id, business_key, reason, credit_resale, expected_version, request_id, note)
CREATE OR REPLACE FUNCTION public.admin_remove_business(
  team_id uuid,
  business_key text,
  reason text,
  credit_resale boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_remove_business.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id, t.version, t.cash
  INTO v_room_id, v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    v_cash := v_cash + v_cost;
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('business_key', business_key, 'reason', reason, 'credit_resale', credit_resale, 'cash', v_cash);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 11. admin_set_bankrupt(team_id, value, expected_version, request_id, note)
CREATE OR REPLACE FUNCTION public.admin_set_bankrupt(
  team_id uuid,
  value boolean,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_curr_bankrupt boolean;
  v_biz RECORD;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_bankrupt.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id, t.version, t.is_bankrupt
  INTO v_room_id, v_curr_ver, v_curr_bankrupt
  FROM public.teams t
  WHERE t.id = team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF NOT value AND (note IS NULL OR trim(note) = '') THEN
    PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'undoing_bankruptcy_requires_note'));
  END IF;

  IF value THEN
    -- Liquidate all owned businesses back to the bank
    FOR v_biz IN SELECT business_key, level FROM public.team_businesses WHERE team_businesses.team_id = admin_set_bankrupt.team_id LOOP
      DELETE FROM public.team_businesses
      WHERE team_businesses.team_id = admin_set_bankrupt.team_id
        AND team_businesses.business_key = v_biz.business_key;

      INSERT INTO public.activity_events (
        room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
      ) VALUES (
        v_room_id, team_id, 'BUSINESS_REMOVED', v_biz.business_key, jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'BANKRUPTCY'), note, v_is_correction, auth.uid(), public.app_now()
      );
    END LOOP;
  END IF;

  UPDATE public.teams
  SET is_bankrupt = value,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BANKRUPTCY_SET',
    jsonb_build_object('is_bankrupt', v_curr_bankrupt),
    jsonb_build_object('is_bankrupt', value),
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 12. admin_set_tiebreak(room_id, ordered_team_ids, note)
CREATE OR REPLACE FUNCTION public.admin_set_tiebreak(
  room_id uuid,
  ordered_team_ids uuid[],
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  i int;
  v_tid uuid;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = room_id FOR UPDATE;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status, 'expected', 'TIME_EXPIRED'));
  END IF;

  -- Clear tiebreak order for all teams in the room first
  UPDATE public.teams
  SET tiebreak_order = NULL
  WHERE public.teams.room_id = admin_set_tiebreak.room_id;

  -- Apply 1-based order for specified teams
  IF ordered_team_ids IS NOT NULL THEN
    FOR i IN 1..array_length(ordered_team_ids, 1) LOOP
      v_tid := ordered_team_ids[i];
      UPDATE public.teams
      SET tiebreak_order = i
      WHERE id = v_tid AND public.teams.room_id = admin_set_tiebreak.room_id;
    END LOOP;
  END IF;

  UPDATE public.rooms
  SET tiebreak_note = note
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id,
    type,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    room_id,
    'TIEBREAK_SET',
    jsonb_build_object('ordered_team_ids', ordered_team_ids),
    note,
    true,
    auth.uid(),
    public.app_now()
  );

  RETURN jsonb_build_object('room_id', room_id, 'ordered_team_ids', ordered_team_ids, 'note', note);
END;
$$;

-- 13. get_admin_snapshot(room_id)
CREATE OR REPLACE FUNCTION public.get_admin_snapshot(room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room jsonb;
  v_teams jsonb;
  v_events jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(room_id);

  SELECT to_jsonb(r.*) INTO v_room
  FROM public.rooms r
  WHERE r.id = room_id;

  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', t.id,
      'slot', t.slot,
      'name', t.name,
      'color', t.color,
      'cash', t.cash,
      'cv', t.cv,
      'is_bankrupt', t.is_bankrupt,
      'version', t.version,
      'tiebreak_order', t.tiebreak_order,
      'claimed', EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id),
      'pin', ts.join_pin,
      'businesses', coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'business_key', tb.business_key,
            'name', bc.name,
            'level', tb.level,
            'cost', bc.cost,
            'initial_cv', bc.initial_cv
          ) ORDER BY bc.sort_order
        )
        FROM public.team_businesses tb
        JOIN public.business_catalog bc ON tb.business_key = bc.key
        WHERE tb.team_id = t.id
      ), '[]'::jsonb)
    ) ORDER BY t.slot
  ), '[]'::jsonb) INTO v_teams
  FROM public.teams t
  LEFT JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE t.room_id = get_admin_snapshot.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ae.id,
      'team_id', ae.team_id,
      'group_id', ae.group_id,
      'type', ae.type,
      'business_key', ae.business_key,
      'prev', ae.prev,
      'new', ae.new,
      'note', ae.note,
      'is_correction', ae.is_correction,
      'created_at', ae.created_at
    ) ORDER BY ae.id DESC
  ), '[]'::jsonb) INTO v_events
  FROM (
    SELECT *
    FROM public.activity_events
    WHERE public.activity_events.room_id = get_admin_snapshot.room_id
    ORDER BY id DESC
    LIMIT 200
  ) ae;

  RETURN jsonb_build_object(
    'room', v_room,
    'server_now', public.app_now(),
    'teams', v_teams,
    'events', v_events
  );
END;
$$;

-- 14. list_history()
CREATE OR REPLACE FUNCTION public.list_history()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_history jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'room_id', r.id,
      'code', r.code,
      'created_at', r.created_at,
      'finalized_at', r.finalized_at,
      'winner_name', w.name,
      'winner_color', w.color,
      'team_count', r.team_count
    ) ORDER BY r.finalized_at DESC NULLS LAST
  ), '[]'::jsonb) INTO v_history
  FROM public.rooms r
  LEFT JOIN public.teams w ON r.winner_team_id = w.id
  WHERE r.status = 'FINALIZED';

  RETURN v_history;
END;
$$;

-- 15. get_history_detail(room_id)
CREATE OR REPLACE FUNCTION public.get_history_detail(room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room jsonb;
  v_results jsonb;
  v_events jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT to_jsonb(r.*) INTO v_room
  FROM public.rooms r
  WHERE r.id = room_id AND r.status = 'FINALIZED';

  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', room_id));
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'team_id', fr.team_id,
      'rank', fr.rank,
      'name', t.name,
      'color', t.color,
      'cv', fr.cv,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) ORDER BY fr.rank ASC
  ), '[]'::jsonb) INTO v_results
  FROM public.final_results fr
  JOIN public.teams t ON fr.team_id = t.id
  WHERE fr.room_id = get_history_detail.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ae.id,
      'team_id', ae.team_id,
      'group_id', ae.group_id,
      'type', ae.type,
      'business_key', ae.business_key,
      'prev', ae.prev,
      'new', ae.new,
      'note', ae.note,
      'is_correction', ae.is_correction,
      'created_at', ae.created_at
    ) ORDER BY ae.id DESC
  ), '[]'::jsonb) INTO v_events
  FROM public.activity_events ae
  WHERE ae.room_id = get_history_detail.room_id;

  RETURN jsonb_build_object(
    'room', v_room,
    'results', v_results,
    'events', v_events
  );
END;
$$;

-- Grant execution to authenticated role for admin functions
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_room(int, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_team_config(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_open_lobby(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_release_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_start_game(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_team_values(uuid, int, int, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust(jsonb, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_business(uuid, text, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_business_level(uuid, text, smallint, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_business(uuid, text, text, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_bankrupt(uuid, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_tiebreak(uuid, uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_snapshot(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_history() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_history_detail(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_team_snapshot(uuid) TO authenticated;


-- Migration 0009: Team-Facing Stored Procedures (Lobby, Join, Isolated Dashboard)
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. get_lobby(code)
CREATE OR REPLACE FUNCTION public.get_lobby(code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(coalesce(code, '')));
  v_room_id uuid;
  v_status public.room_status;
  v_team_count smallint;
  v_teams jsonb;
BEGIN
  SELECT id, status, team_count INTO v_room_id, v_status, v_team_count
  FROM public.rooms
  WHERE public.rooms.code = v_code
    AND status IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED');

  IF NOT FOUND THEN
    PERFORM public.raise_error('BAD_CODE_OR_PIN', jsonb_build_object('code', code));
  END IF;

  v_status := public.expire_if_due(v_room_id);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'slot', t.slot,
      'name', t.name,
      'color', t.color,
      'claimed', EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id)
    ) ORDER BY t.slot ASC
  ), '[]'::jsonb) INTO v_teams
  FROM public.teams t
  WHERE t.room_id = v_room_id;

  RETURN jsonb_build_object(
    'status', v_status,
    'team_count', v_team_count,
    'teams', v_teams
  );
END;
$$;

-- 2. join_team(code, slot, pin)
CREATE OR REPLACE FUNCTION public.join_team(
  code text,
  slot int,
  pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text := upper(trim(coalesce(code, '')));
  v_pin text := trim(coalesce(pin, ''));
  v_fail_count int;
  v_room_id uuid;
  v_status public.room_status;
  v_team_id uuid;
  v_name text;
  v_real_pin text;
  v_first_claim boolean;
BEGIN
  IF v_user_id IS NULL THEN
    PERFORM public.raise_error('NOT_AUTHENTICATED');
  END IF;

  -- Throttling: Max 5 failed attempts in the last 60 seconds for this user
  SELECT count(*) INTO v_fail_count
  FROM public.join_attempts
  WHERE user_id = v_user_id
    AND success = false
    AND attempted_at >= public.app_now() - interval '60 seconds';

  IF v_fail_count >= 5 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  -- Validate room
  SELECT id, status INTO v_room_id, v_status
  FROM public.rooms
  WHERE public.rooms.code = v_code
    AND status IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED');

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());

    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- Validate team slot
  SELECT id, name INTO v_team_id, v_name
  FROM public.teams
  WHERE room_id = v_room_id AND teams.slot = join_team.slot;

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());

    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- Validate PIN
  SELECT join_pin INTO v_real_pin
  FROM public.team_secrets
  WHERE team_id = v_team_id;

  IF v_real_pin IS DISTINCT FROM v_pin THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, false, public.app_now());

    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- Success: log attempt, record claim
  INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
  VALUES (v_user_id, v_team_id, true, public.app_now());

  v_first_claim := NOT EXISTS (
    SELECT 1 FROM public.team_claims WHERE team_claims.team_id = v_team_id
  );

  INSERT INTO public.team_claims (user_id, team_id, claimed_at)
  VALUES (v_user_id, v_team_id, public.app_now())
  ON CONFLICT (user_id, team_id) DO NOTHING;

  IF v_first_claim THEN
    INSERT INTO public.activity_events (
      room_id,
      team_id,
      type,
      new,
      actor_id,
      created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      'TEAM_CLAIMED',
      jsonb_build_object('slot', slot, 'name', v_name),
      v_user_id,
      public.app_now()
    );
  END IF;

  RETURN jsonb_build_object('team_id', v_team_id, 'room_id', v_room_id);
END;
$$;

-- 3. get_my_state()
CREATE OR REPLACE FUNCTION public.get_my_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_room_id uuid;
  v_status public.room_status;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_slot smallint;
  v_name text;
  v_color text;
  v_cash int;
  v_cv int;
  v_is_bankrupt boolean;
  v_businesses jsonb;
  v_leaderboard jsonb := NULL;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Priority 1: User's claim in a non-FINALIZED room
  SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
  FROM public.team_claims tc
  JOIN public.teams t ON tc.team_id = t.id
  JOIN public.rooms r ON t.room_id = r.id
  WHERE tc.user_id = v_user_id AND r.status <> 'FINALIZED'
  ORDER BY tc.claimed_at DESC
  LIMIT 1;

  -- Priority 2: User's claim in the most recently finalized room
  IF v_room_id IS NULL THEN
    SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
    FROM public.team_claims tc
    JOIN public.teams t ON tc.team_id = t.id
    JOIN public.rooms r ON t.room_id = r.id
    WHERE tc.user_id = v_user_id AND r.status = 'FINALIZED'
    ORDER BY r.finalized_at DESC NULLS LAST, tc.claimed_at DESC
    LIMIT 1;
  END IF;

  IF v_room_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_status := public.expire_if_due(v_room_id);

  SELECT status, started_at, ends_at INTO v_status, v_started_at, v_ends_at
  FROM public.rooms
  WHERE id = v_room_id;

  SELECT slot, name, color, cash, cv, is_bankrupt
  INTO v_slot, v_name, v_color, v_cash, v_cv, v_is_bankrupt
  FROM public.teams
  WHERE id = v_team_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost,
      'initial_cv', bc.initial_cv,
      'cv_contribution', bc.initial_cv + (CASE WHEN tb.level >= 1 THEN bc.u1_cv ELSE 0 END) + (CASE WHEN tb.level >= 2 THEN bc.u2_cv ELSE 0 END)
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = v_team_id;

  IF v_status = 'FINALIZED' THEN
    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'rank', fr.rank,
        'name', t.name,
        'color', t.color,
        'cv', fr.cv,
        'cash', fr.cash,
        'business_count', fr.business_count,
        'is_bankrupt', fr.is_bankrupt
      ) ORDER BY fr.rank ASC
    ), '[]'::jsonb) INTO v_leaderboard
    FROM public.final_results fr
    JOIN public.teams t ON fr.team_id = t.id
    WHERE fr.room_id = v_room_id;
  END IF;

  RETURN jsonb_build_object(
    'room', jsonb_build_object(
      'status', v_status,
      'started_at', v_started_at,
      'ends_at', v_ends_at,
      'server_now', public.app_now()
    ),
    'team', jsonb_build_object(
      'slot', v_slot,
      'name', v_name,
      'color', v_color,
      'cash', v_cash,
      'cv', v_cv,
      'is_bankrupt', v_is_bankrupt
    ),
    'businesses', v_businesses,
    'leaderboard', v_leaderboard
  );
END;
$$;

-- Permissions
REVOKE ALL ON FUNCTION public.get_lobby(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_lobby(text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.join_team(text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_team(text, int, text) TO authenticated, anon;

REVOKE ALL ON FUNCTION public.get_my_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_state() TO authenticated, anon;


-- Migration 0010: Standings, Tiebreaks, and Finalization
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. room_standings(p_room_id) Table Function
CREATE OR REPLACE FUNCTION public.room_standings(p_room_id uuid)
RETURNS TABLE (
  team_id uuid,
  slot smallint,
  name text,
  rank int,
  is_bankrupt boolean,
  cv int,
  cash int,
  business_count int,
  tiebreak_order smallint,
  tie_unresolved boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH team_biz AS (
    SELECT t.id AS tid, count(tb.id)::int AS b_count
    FROM public.teams t
    LEFT JOIN public.team_businesses tb ON t.id = tb.team_id
    WHERE t.room_id = p_room_id
    GROUP BY t.id
  ),
  base AS (
    SELECT
      t.id AS tid,
      t.slot,
      t.name,
      t.is_bankrupt,
      t.cv,
      t.cash,
      tbz.b_count AS business_count,
      t.tiebreak_order,
      count(*) OVER (PARTITION BY t.is_bankrupt, t.cv, t.cash, tbz.b_count) AS tie_group_size,
      count(t.tiebreak_order) OVER (PARTITION BY t.is_bankrupt, t.cv, t.cash, tbz.b_count) AS count_with_order
    FROM public.teams t
    JOIN team_biz tbz ON t.id = tbz.tid
    WHERE t.room_id = p_room_id
  ),
  -- Compute distinct tiebreak_order count per tie-group using a plain GROUP BY
  tie_distinct AS (
    SELECT
      b.is_bankrupt AS td_bankrupt,
      b.cv          AS td_cv,
      b.cash        AS td_cash,
      b.business_count AS td_biz,
      count(DISTINCT b.tiebreak_order) AS distinct_orders
    FROM base b
    GROUP BY b.is_bankrupt, b.cv, b.cash, b.business_count
  )
  SELECT
    b.tid AS team_id,
    b.slot,
    b.name,
    row_number() OVER (
      ORDER BY
        b.is_bankrupt ASC,
        b.cv DESC,
        b.cash DESC,
        b.business_count DESC,
        b.tiebreak_order ASC NULLS LAST,
        b.slot ASC
    )::int AS rank,
    b.is_bankrupt,
    b.cv,
    b.cash,
    b.business_count,
    b.tiebreak_order,
    (b.tie_group_size > 1 AND (b.count_with_order < b.tie_group_size OR td.distinct_orders < b.tie_group_size)) AS tie_unresolved
  FROM base b
  JOIN tie_distinct td
    ON b.is_bankrupt = td.td_bankrupt
   AND b.cv = td.td_cv
   AND b.cash = td.td_cash
   AND b.business_count = td.td_biz
  ORDER BY rank ASC;
END;
$$;

-- 2. get_standings(p_room_id) Admin Wrapper
CREATE OR REPLACE FUNCTION public.get_standings(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_standings jsonb;
  v_has_unresolved boolean;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  SELECT EXISTS (
    SELECT 1 FROM public.room_standings(p_room_id) s WHERE s.tie_unresolved = true
  ) INTO v_has_unresolved;

  RETURN jsonb_build_object(
    'standings', v_standings,
    'has_unresolved_tie', v_has_unresolved
  );
END;
$$;

-- 3. admin_finalize(p_room_id)
CREATE OR REPLACE FUNCTION public.admin_finalize(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_tied_ids jsonb;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Block finalize if any tie is unresolved
  SELECT jsonb_agg(s.team_id) INTO v_tied_ids
  FROM public.room_standings(p_room_id) s
  WHERE s.tie_unresolved = true;

  IF v_tied_ids IS NOT NULL AND jsonb_array_length(v_tied_ids) > 0 THEN
    PERFORM public.raise_error('UNRESOLVED_TIE', jsonb_build_object('tied_team_ids', v_tied_ids));
  END IF;

  -- Snapshot into final_results table
  INSERT INTO public.final_results (
    room_id,
    team_id,
    rank,
    cv,
    cash,
    business_count,
    is_bankrupt
  )
  SELECT
    p_room_id,
    s.team_id,
    s.rank::smallint,
    s.cv,
    s.cash,
    s.business_count::smallint,
    s.is_bankrupt
  FROM public.room_standings(p_room_id) s;

  -- Winner is rank 1 active team (NULL if all bankrupt)
  SELECT s.team_id INTO v_winner_id
  FROM public.room_standings(p_room_id) s
  WHERE s.rank = 1 AND s.is_bankrupt = false;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    p_room_id,
    'GAME_FINALIZED',
    'Match finalized. Leaderboard permanently snapshotted.',
    auth.uid(),
    public.app_now()
  );

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  RETURN jsonb_build_object(
    'room_id', p_room_id,
    'winner_team_id', v_winner_id,
    'standings', v_standings
  );
END;
$$;

-- Permissions
REVOKE ALL ON FUNCTION public.room_standings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.room_standings(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_standings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_standings(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_finalize(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_finalize(uuid) TO authenticated;


-- Migration 0011: Performance Indexes and Realtime Optimization
-- STARTUPOLY Live Scoreboard & Game Management System

-- 1. Explicit index for room_id filtering on team_businesses
CREATE INDEX IF NOT EXISTS idx_team_businesses_room_id ON public.team_businesses(room_id);

-- 2. Index for status queries on rooms
CREATE INDEX IF NOT EXISTS idx_rooms_status ON public.rooms(status);

-- 3. Index on final_results for room queries
CREATE INDEX IF NOT EXISTS idx_final_results_room_id ON public.final_results(room_id);

-- 4. Verification comment: All RLS and Realtime filter paths are btree-indexed
-- - rooms: id (PK), code (unique index), status (idx_rooms_status)
-- - teams: id (PK), room_id (idx_teams_room_id)
-- - team_businesses: room_id (idx_team_businesses_room_id), team_id (idx_team_businesses_team_id)
-- - activity_events: room_id + id DESC (idx_activity_events_room_id_id)
-- - team_claims: user_id + team_id (PK), team_id (idx_team_claims_team_id)


-- Migration 0012: Admin Abort Game Function
-- STARTUPOLY Live Scoreboard & Game Management System
-- Allows admin to revert an accidentally started match back to LOBBY

CREATE OR REPLACE FUNCTION public.admin_abort_game(
  room_id uuid,
  note text DEFAULT 'Game aborted by admin'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  -- Reset room back to LOBBY
  UPDATE public.rooms
  SET status = 'LOBBY',
      started_at = NULL,
      ends_at = NULL
  WHERE id = room_id;

  -- Log the abort event
  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    room_id,
    'GAME_ABORTED',
    coalesce(note, 'Game aborted by admin'),
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_abort_game(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_abort_game(uuid, text) TO authenticated;


-- Migration 0013: Fix Admin Abort Reset
-- STARTUPOLY Live Scoreboard & Game Management System
-- Reverts match to LOBBY, resets team cash/cv/bankrupt/tiebreak to baseline, deletes businesses,
-- increments team versions, records audit events, and requires a non-empty note.

DROP FUNCTION IF EXISTS public.admin_abort_game(uuid, text);

CREATE OR REPLACE FUNCTION public.admin_abort_game(
  p_room_id uuid,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_room jsonb;
  v_biz RECORD;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF note IS NULL OR trim(note) = '' THEN
    PERFORM public.raise_error('NOTE_REQUIRED');
  END IF;

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  -- Lock teams in deterministic ID order to prevent deadlocks
  PERFORM 1
  FROM public.teams
  WHERE room_id = p_room_id
  ORDER BY id ASC
  FOR UPDATE;

  -- Reset room back to LOBBY
  UPDATE public.rooms
  SET status = 'LOBBY',
      started_at = NULL,
      ends_at = NULL
  WHERE id = p_room_id;

  -- Record audit events for removed businesses
  FOR v_biz IN
    SELECT tb.team_id, tb.business_key, tb.level
    FROM public.team_businesses tb
    JOIN public.teams t ON tb.team_id = t.id
    WHERE t.room_id = p_room_id
  LOOP
    INSERT INTO public.activity_events (
      room_id,
      team_id,
      type,
      business_key,
      prev,
      new,
      note,
      is_correction,
      actor_id,
      created_at
    ) VALUES (
      p_room_id,
      v_biz.team_id,
      'BUSINESS_REMOVED',
      v_biz.business_key,
      jsonb_build_object('level', v_biz.level),
      jsonb_build_object('reason', 'CORRECTION'),
      trim(note),
      true,
      auth.uid(),
      public.app_now()
    );
  END LOOP;

  -- Delete all team businesses for this room
  DELETE FROM public.team_businesses
  WHERE team_id IN (
    SELECT id FROM public.teams WHERE room_id = p_room_id
  );

  -- Reset all teams in the room back to LOBBY baseline and increment version
  UPDATE public.teams
  SET cash = 1000,
      cv = 0,
      is_bankrupt = false,
      tiebreak_order = NULL,
      version = version + 1
  WHERE room_id = p_room_id;

  -- Log the abort event with reset details
  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    prev,
    new,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    p_room_id,
    'GAME_ABORTED',
    trim(note),
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('status', 'LOBBY', 'teams_reset', true),
    true,
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_abort_game(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_abort_game(uuid, text) TO authenticated;


-- Migration 0014: Enforce one active phone claim per team
-- A team slot may be claimed by exactly one anonymous session at a time.
-- Admin release remains the explicit recovery path for a lost phone/session.

BEGIN;

-- Recover from claims created by the old loophole. Keep the earliest claim and
-- require an organiser to release it if the original session is unavailable.
DELETE FROM public.team_claims AS duplicate_claim
USING public.team_claims AS retained_claim
WHERE duplicate_claim.team_id = retained_claim.team_id
  AND (
    duplicate_claim.claimed_at > retained_claim.claimed_at
    OR (
      duplicate_claim.claimed_at = retained_claim.claimed_at
      AND duplicate_claim.user_id > retained_claim.user_id
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_team_claims_one_active_claim_per_team
  ON public.team_claims (team_id);

CREATE OR REPLACE FUNCTION public.join_team(
  code text,
  slot int,
  pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text := upper(trim(coalesce(code, '')));
  v_pin text := trim(coalesce(pin, ''));
  v_fail_count int;
  v_room_id uuid;
  v_status public.room_status;
  v_team_id uuid;
  v_name text;
  v_real_pin text;
  v_first_claim boolean;
BEGIN
  IF v_user_id IS NULL THEN
    PERFORM public.raise_error('NOT_AUTHENTICATED');
  END IF;

  SELECT count(*) INTO v_fail_count
  FROM public.join_attempts
  WHERE user_id = v_user_id
    AND success = false
    AND attempted_at >= public.app_now() - interval '60 seconds';

  IF v_fail_count >= 5 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  SELECT id, status INTO v_room_id, v_status
  FROM public.rooms
  WHERE public.rooms.code = v_code
    AND status IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED');

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  SELECT id, name INTO v_team_id, v_name
  FROM public.teams
  WHERE room_id = v_room_id AND teams.slot = join_team.slot;

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  SELECT join_pin INTO v_real_pin
  FROM public.team_secrets
  WHERE team_id = v_team_id;

  IF v_real_pin IS DISTINCT FROM v_pin THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- The PIN proves the team invitation, but it must not allow a second
  -- anonymous phone to take over an already-connected slot.
  IF EXISTS (
    SELECT 1
    FROM public.team_claims
    WHERE team_id = v_team_id
      AND user_id <> v_user_id
  ) THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, false, public.app_now());
    PERFORM public.raise_error('TEAM_ALREADY_CLAIMED');
  END IF;

  INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
  VALUES (v_user_id, v_team_id, true, public.app_now());

  v_first_claim := NOT EXISTS (
    SELECT 1 FROM public.team_claims WHERE team_id = v_team_id
  );

  INSERT INTO public.team_claims (user_id, team_id, claimed_at)
  VALUES (v_user_id, v_team_id, public.app_now())
  ON CONFLICT (user_id, team_id) DO NOTHING;

  IF v_first_claim THEN
    INSERT INTO public.activity_events (
      room_id, team_id, type, new, actor_id, created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      'TEAM_CLAIMED',
      jsonb_build_object('slot', slot, 'name', v_name),
      v_user_id,
      public.app_now()
    );
  END IF;

  RETURN jsonb_build_object('team_id', v_team_id, 'room_id', v_room_id);
END;
$$;

REVOKE ALL ON FUNCTION public.join_team(text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_team(text, int, text) TO anon, authenticated;

COMMIT;


-- Migration 0015: Enforce player privacy at the database and RLS layers
-- 1. get_my_state() must NEVER return other teams' names, colors, cash, CV, business counts or rankings.
--    Removes the full tournament leaderboard from the player RPC response.
--    When a room is finalized, returns ONLY the calling team's own final_result.
-- 2. Restricts RLS on public.final_results so claimed users can ONLY select their own team's final result row.

BEGIN;

-- 1. Restrict RLS on public.final_results to own team row only
DROP POLICY IF EXISTS "Claimed users can select final results when room is finalized" ON public.final_results;

CREATE POLICY "Claimed users can select own final result when room is finalized"
  ON public.final_results
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_claims tc
      JOIN public.rooms r ON r.id = public.final_results.room_id
      WHERE tc.team_id = public.final_results.team_id
        AND tc.user_id = (SELECT auth.uid())
        AND r.status = 'FINALIZED'
    )
  );

-- 2. Update get_my_state() to return strictly caller's own team state and final_result
CREATE OR REPLACE FUNCTION public.get_my_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_room_id uuid;
  v_status public.room_status;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_slot smallint;
  v_name text;
  v_color text;
  v_cash int;
  v_cv int;
  v_is_bankrupt boolean;
  v_businesses jsonb;
  v_final_result jsonb := NULL;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Priority 1: User's claim in a non-FINALIZED room
  SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
  FROM public.team_claims tc
  JOIN public.teams t ON tc.team_id = t.id
  JOIN public.rooms r ON t.room_id = r.id
  WHERE tc.user_id = v_user_id AND r.status <> 'FINALIZED'
  ORDER BY tc.claimed_at DESC
  LIMIT 1;

  -- Priority 2: User's claim in the most recently finalized room
  IF v_room_id IS NULL THEN
    SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
    FROM public.team_claims tc
    JOIN public.teams t ON tc.team_id = t.id
    JOIN public.rooms r ON t.room_id = r.id
    WHERE tc.user_id = v_user_id AND r.status = 'FINALIZED'
    ORDER BY r.finalized_at DESC NULLS LAST, tc.claimed_at DESC
    LIMIT 1;
  END IF;

  IF v_room_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_status := public.expire_if_due(v_room_id);

  SELECT status, started_at, ends_at INTO v_status, v_started_at, v_ends_at
  FROM public.rooms
  WHERE id = v_room_id;

  SELECT slot, name, color, cash, cv, is_bankrupt
  INTO v_slot, v_name, v_color, v_cash, v_cv, v_is_bankrupt
  FROM public.teams
  WHERE id = v_team_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost,
      'initial_cv', bc.initial_cv,
      'cv_contribution', bc.initial_cv + (CASE WHEN tb.level >= 1 THEN bc.u1_cv ELSE 0 END) + (CASE WHEN tb.level >= 2 THEN bc.u2_cv ELSE 0 END)
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = v_team_id;

  IF v_status = 'FINALIZED' THEN
    SELECT jsonb_build_object(
      'rank', fr.rank,
      'cv', fr.cv,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) INTO v_final_result
    FROM public.final_results fr
    WHERE fr.room_id = v_room_id AND fr.team_id = v_team_id;
  END IF;

  RETURN jsonb_build_object(
    'room', jsonb_build_object(
      'status', v_status,
      'started_at', v_started_at,
      'ends_at', v_ends_at,
      'server_now', public.app_now()
    ),
    'team', jsonb_build_object(
      'slot', v_slot,
      'name', v_name,
      'color', v_color,
      'cash', v_cash,
      'cv', v_cv,
      'is_bankrupt', v_is_bankrupt
    ),
    'businesses', v_businesses,
    'final_result', v_final_result
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_state() TO authenticated, anon;

COMMIT;


-- Migration 0016: Canonical lock order
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- CANONICAL LOCK ORDER for every mutating RPC (docs/OPERATIONS.md):
--   1) rooms row            (FOR UPDATE; expire_if_due takes it)
--   2) teams rows of that room, ascending id
--   3) team_businesses / activity_events writes (no explicit locks)
-- The room row is the single serialization point for lifecycle (start/abort/finalize/expire),
-- so taking it first makes lifecycle-vs-money races queue instead of deadlock (40P01).
--
-- Changed here: admin_add_business, admin_set_business_level, admin_remove_business,
-- admin_set_bankrupt (previously team THEN room) and admin_release_team (JOIN ... FOR UPDATE).
-- Already canonical, verified unchanged: admin_set_team_values, admin_adjust, admin_abort_game,
-- admin_finalize, expire_if_due. Inputs, outputs, error codes and grants are unchanged.

CREATE OR REPLACE FUNCTION public.admin_add_business(
  team_id uuid,
  business_key text,
  apply_purchase boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_cost int;
  v_initial_cv int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_add_business.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash, t.cv
  INTO v_is_bankrupt, v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 3 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, initial_cv INTO v_cost, v_initial_cv
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key);

  IF apply_purchase THEN
    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
    v_cv := v_cv + v_initial_cv;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_level(
  team_id uuid,
  business_key text,
  new_level smallint,
  apply_upgrade boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_curr_level smallint;
  v_cost int;
  v_cv_gain int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_business_level.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash, t.cv
  INTO v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash, 'cv', v_cv);

  IF apply_upgrade THEN
    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost, u1_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost, u2_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
    v_cv := v_cv + v_cv_gain;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'cv', v_cv, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_business(
  team_id uuid,
  business_key text,
  reason text,
  credit_resale boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_remove_business.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash
  INTO v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    v_cash := v_cash + v_cost;
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('business_key', business_key, 'reason', reason, 'credit_resale', credit_resale, 'cash', v_cash);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_bankrupt(
  team_id uuid,
  value boolean,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_curr_bankrupt boolean;
  v_biz RECORD;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_bankrupt.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.is_bankrupt
  INTO v_curr_ver, v_curr_bankrupt
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF NOT value AND (note IS NULL OR trim(note) = '') THEN
    PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'undoing_bankruptcy_requires_note'));
  END IF;

  IF value THEN
    -- Liquidate all owned businesses back to the bank
    FOR v_biz IN SELECT business_key, level FROM public.team_businesses WHERE team_businesses.team_id = admin_set_bankrupt.team_id LOOP
      DELETE FROM public.team_businesses
      WHERE team_businesses.team_id = admin_set_bankrupt.team_id
        AND team_businesses.business_key = v_biz.business_key;

      INSERT INTO public.activity_events (
        room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
      ) VALUES (
        v_room_id, team_id, 'BUSINESS_REMOVED', v_biz.business_key, jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'BANKRUPTCY'), note, v_is_correction, auth.uid(), public.app_now()
      );
    END LOOP;
  END IF;

  UPDATE public.teams
  SET is_bankrupt = value,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BANKRUPTCY_SET',
    jsonb_build_object('is_bankrupt', v_curr_bankrupt),
    jsonb_build_object('is_bankrupt', value),
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_release_team(team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  PERFORM 1 FROM public.teams t WHERE t.id = team_id AND t.room_id = v_room_id FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_status NOT IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED') THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  DELETE FROM public.team_claims WHERE team_claims.team_id = admin_release_team.team_id;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    'TEAM_RELEASED',
    'Team slot released by admin',
    auth.uid(),
    public.app_now()
  );

  RETURN jsonb_build_object('team_id', team_id, 'released', true);
END;
$$;


-- Migration 0017: Lifecycle hardening
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- 1. admin_abort_game calls expire_if_due first and raises ROOM_ALREADY_EXPIRED (new code) for a
--    finished game. An expired game is closed with admin_finalize, never aborted.
-- 2. admin_open_lobby / admin_start_game / admin_abort_game / admin_finalize take an optional
--    request_id. It is stored on the lifecycle event (activity_events.request_id is UNIQUE).
--    Replay rule, evaluated AFTER the room lock: same room + same event type => return the
--    first call's payload shape; any other use of the id => REQUEST_ID_REUSED (new code).
-- 3. admin_start_game re-checks the initial state inside the lock (INVALID_INITIAL_STATE, new code)
--    and derives the countdown text from duration_seconds.
-- 4. expire_if_due is no longer executable by anon (it was a room-existence oracle). It is still
--    called from SECURITY DEFINER readers (get_lobby, get_my_state, ...), which run as the owner.
--
-- Lock order is unchanged (docs/OPERATIONS.md): room first, then teams ascending id.

-- Private helper: true = replay, false = first use, raises on misuse. Call only while holding the room lock.
CREATE OR REPLACE FUNCTION public.lifecycle_replay_check(p_room_id uuid, p_request_id uuid, p_type text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room uuid;
  v_type text;
BEGIN
  IF p_request_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT ae.room_id, ae.type INTO v_room, v_type
  FROM public.activity_events ae
  WHERE ae.request_id = p_request_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_room IS DISTINCT FROM p_room_id OR v_type <> p_type THEN
    PERFORM public.raise_error('REQUEST_ID_REUSED', jsonb_build_object('request_id', p_request_id));
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.lifecycle_replay_check(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- admin_open_lobby
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_open_lobby(uuid);

CREATE FUNCTION public.admin_open_lobby(room_id uuid, request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(room_id, request_id, 'LOBBY_OPENED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
    RETURN v_room;
  END IF;

  IF v_status <> 'CREATED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  UPDATE public.rooms
  SET status = 'LOBBY'
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    room_id, request_id, 'LOBBY_OPENED', 'Lobby opened for team connections', auth.uid(), public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_open_lobby(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_open_lobby(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- admin_start_game
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_start_game(uuid, boolean);

CREATE FUNCTION public.admin_start_game(
  room_id uuid,
  force boolean DEFAULT false,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_duration int;
  v_team_count int;
  v_started_prev timestamptz;
  v_ends_prev timestamptz;
  v_unclaimed_slots jsonb;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status, duration_seconds, team_count, started_at, ends_at
  INTO v_status, v_duration, v_team_count, v_started_prev, v_ends_prev
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(room_id, request_id, 'GAME_STARTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
    RETURN v_room;
  END IF;

  IF v_status <> 'LOBBY' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'ACTIVE'));
  END IF;

  -- Defense in depth: a LOBBY room must be pristine.
  IF v_started_prev IS NOT NULL OR v_ends_prev IS NOT NULL
     OR (SELECT count(*) FROM public.teams t WHERE t.room_id = admin_start_game.room_id) <> v_team_count
     OR EXISTS (
       SELECT 1 FROM public.teams t
       WHERE t.room_id = admin_start_game.room_id
         AND (t.cash <> 1000 OR t.cv <> 0 OR t.is_bankrupt
              OR EXISTS (SELECT 1 FROM public.team_businesses tb WHERE tb.team_id = t.id))
     ) THEN
    PERFORM public.raise_error('INVALID_INITIAL_STATE', jsonb_build_object('room_id', room_id));
  END IF;

  IF NOT force THEN
    SELECT jsonb_agg(t.slot ORDER BY t.slot) INTO v_unclaimed_slots
    FROM public.teams t
    WHERE t.room_id = admin_start_game.room_id
      AND NOT EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id);

    IF v_unclaimed_slots IS NOT NULL AND jsonb_array_length(v_unclaimed_slots) > 0 THEN
      PERFORM public.raise_error('TEAMS_NOT_JOINED', jsonb_build_object('unclaimed_slots', v_unclaimed_slots));
    END IF;
  END IF;

  v_started_at := public.app_now();
  v_ends_at := v_started_at + (v_duration || ' seconds')::interval;

  UPDATE public.rooms
  SET status = 'ACTIVE',
      started_at = v_started_at,
      ends_at = v_ends_at
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    room_id,
    request_id,
    'GAME_STARTED',
    format('Gameplay started. %s:%s countdown active.', lpad((v_duration / 60)::text, 2, '0'), lpad((v_duration % 60)::text, 2, '0')),
    auth.uid(),
    v_started_at
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_start_game(uuid, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_start_game(uuid, boolean, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- admin_abort_game (ACTIVE -> LOBBY with team reset; expired games are finalized, not aborted)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_abort_game(uuid, text);

CREATE FUNCTION public.admin_abort_game(
  p_room_id uuid,
  note text DEFAULT NULL,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_room jsonb;
  v_biz RECORD;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF note IS NULL OR trim(note) = '' THEN
    PERFORM public.raise_error('NOTE_REQUIRED');
  END IF;

  -- Flip a passed deadline to TIME_EXPIRED first (takes the room lock).
  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_ABORTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
    RETURN v_room;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('ROOM_ALREADY_EXPIRED', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  -- Lock teams in deterministic ID order to prevent deadlocks
  PERFORM 1
  FROM public.teams
  WHERE room_id = p_room_id
  ORDER BY id ASC
  FOR UPDATE;

  UPDATE public.rooms
  SET status = 'LOBBY',
      started_at = NULL,
      ends_at = NULL
  WHERE id = p_room_id;

  FOR v_biz IN
    SELECT tb.team_id, tb.business_key, tb.level
    FROM public.team_businesses tb
    JOIN public.teams t ON tb.team_id = t.id
    WHERE t.room_id = p_room_id
  LOOP
    INSERT INTO public.activity_events (
      room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      p_room_id, v_biz.team_id, 'BUSINESS_REMOVED', v_biz.business_key,
      jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'CORRECTION'),
      trim(note), true, auth.uid(), public.app_now()
    );
  END LOOP;

  DELETE FROM public.team_businesses
  WHERE team_id IN (
    SELECT id FROM public.teams WHERE room_id = p_room_id
  );

  UPDATE public.teams
  SET cash = 1000,
      cv = 0,
      is_bankrupt = false,
      tiebreak_order = NULL,
      version = version + 1
  WHERE room_id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, prev, new, is_correction, actor_id, created_at
  ) VALUES (
    p_room_id,
    request_id,
    'GAME_ABORTED',
    trim(note),
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('status', 'LOBBY', 'teams_reset', true),
    true,
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_abort_game(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_abort_game(uuid, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- admin_finalize
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_finalize(uuid);

CREATE FUNCTION public.admin_finalize(p_room_id uuid, request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_tied_ids jsonb;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_FINALIZED') THEN
    SELECT winner_team_id INTO v_winner_id FROM public.rooms WHERE id = p_room_id;
    SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
    INTO v_standings
    FROM public.room_standings(p_room_id) s;
    RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
  END IF;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Block finalize if any tie is unresolved
  SELECT jsonb_agg(s.team_id) INTO v_tied_ids
  FROM public.room_standings(p_room_id) s
  WHERE s.tie_unresolved = true;

  IF v_tied_ids IS NOT NULL AND jsonb_array_length(v_tied_ids) > 0 THEN
    PERFORM public.raise_error('UNRESOLVED_TIE', jsonb_build_object('tied_team_ids', v_tied_ids));
  END IF;

  INSERT INTO public.final_results (room_id, team_id, rank, cv, cash, business_count, is_bankrupt)
  SELECT p_room_id, s.team_id, s.rank::smallint, s.cv, s.cash, s.business_count::smallint, s.is_bankrupt
  FROM public.room_standings(p_room_id) s;

  SELECT s.team_id INTO v_winner_id
  FROM public.room_standings(p_room_id) s
  WHERE s.rank = 1 AND s.is_bankrupt = false;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    p_room_id, request_id, 'GAME_FINALIZED', 'Match finalized. Leaderboard permanently snapshotted.', auth.uid(), public.app_now()
  );

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_finalize(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_finalize(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- expire_if_due: not callable by anon (room-existence oracle). Definer readers still use it.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.expire_if_due(uuid) FROM anon;


-- Migration 0018: Money RPC hardening
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- 1. request_id replay is evaluated AFTER the room and team locks, so a retry that arrives while the
--    original is in flight waits and then replays instead of failing with VERSION_CONFLICT/BUSINESS_OWNED.
--    A replay must match the room, the team (where one applies), the event family and the actor;
--    anything else raises REQUEST_ID_REUSED (added in 0017). A replay returns the same shape as the
--    first call (admin_adjust: the array of team snapshots, no more 'idempotent_duplicate').
-- 2. Money is capped at public.max_money() (1,000,000,000, far above any rulebook value). Arithmetic is
--    checked in bigint before it can overflow int; violations raise INVALID_VALUE with the field.
--    teams.cash / teams.cv get matching CHECK constraints.
-- 3. admin_adjust validates `changes` up front (array of 1..6 objects, uuid team_id, integer deltas,
--    required expected_version, no duplicate team, one room).
-- 4. admin_set_team_values leaves a no-op call untouched (no version bump), so a retry of a no-op
--    cannot turn into VERSION_CONFLICT.
--
-- Deliberately editable after TIME_EXPIRED (note required, is_correction = true): set_team_values,
-- adjust, add/level/remove business, set_bankrupt. After FINALIZED every one raises ROOM_NOT_EDITABLE.
-- Costs, resale, upgrade and CV rules are unchanged.

CREATE OR REPLACE FUNCTION public.max_money()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 1000000000 $$;

REVOKE ALL ON FUNCTION public.max_money() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.teams ADD CONSTRAINT teams_cash_cap CHECK (cash <= 1000000000) NOT VALID;
ALTER TABLE public.teams ADD CONSTRAINT teams_cv_cap CHECK (cv <= 1000000000) NOT VALID;
ALTER TABLE public.teams VALIDATE CONSTRAINT teams_cash_cap;
ALTER TABLE public.teams VALIDATE CONSTRAINT teams_cv_cap;

-- Private helper: true = replay, false = first use, raises REQUEST_ID_REUSED on misuse.
-- Call only while holding the room and team locks. p_team_id NULL skips the team check (admin_adjust).
CREATE OR REPLACE FUNCTION public.money_replay_check(p_room_id uuid, p_team_id uuid, p_request_id uuid, p_types text[])
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ev RECORD;
BEGIN
  IF p_request_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT ae.room_id, ae.team_id, ae.type, ae.actor_id INTO v_ev
  FROM public.activity_events ae
  WHERE ae.request_id = p_request_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_ev.room_id IS DISTINCT FROM p_room_id
     OR NOT (v_ev.type = ANY (p_types))
     OR v_ev.actor_id IS DISTINCT FROM auth.uid()
     OR (p_team_id IS NOT NULL AND v_ev.team_id IS DISTINCT FROM p_team_id) THEN
    PERFORM public.raise_error('REQUEST_ID_REUSED', jsonb_build_object('request_id', p_request_id));
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.money_replay_check(uuid, uuid, uuid, text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_add_business(
  team_id uuid,
  business_key text,
  apply_purchase boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_cost int;
  v_initial_cv int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash, t.cv
  INTO v_is_bankrupt, v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_ADDED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 3 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, initial_cv INTO v_cost, v_initial_cv
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key);

  IF apply_purchase THEN
    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
    IF v_cv::bigint + v_initial_cv > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'max', public.max_money()));
    END IF;
    v_cv := v_cv + v_initial_cv;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_level(
  team_id uuid,
  business_key text,
  new_level smallint,
  apply_upgrade boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_curr_level smallint;
  v_cost int;
  v_cv_gain int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash, t.cv
  INTO v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_LEVEL_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash, 'cv', v_cv);

  IF apply_upgrade THEN
    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost, u1_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost, u2_cv INTO v_cost, v_cv_gain FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
    IF v_cv::bigint + v_cv_gain > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'max', public.max_money()));
    END IF;
    v_cv := v_cv + v_cv_gain;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'cv', v_cv, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_business(
  team_id uuid,
  business_key text,
  reason text,
  credit_resale boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash
  INTO v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_REMOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    IF v_cash::bigint + v_cost > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
    END IF;
    v_cash := v_cash + v_cost;
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('business_key', business_key, 'reason', reason, 'credit_resale', credit_resale, 'cash', v_cash);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_bankrupt(
  team_id uuid,
  value boolean,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_curr_bankrupt boolean;
  v_biz RECORD;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.is_bankrupt
  INTO v_curr_ver, v_curr_bankrupt
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BANKRUPTCY_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF NOT value AND (note IS NULL OR trim(note) = '') THEN
    PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'undoing_bankruptcy_requires_note'));
  END IF;

  IF value THEN
    -- Liquidate all owned businesses back to the bank
    FOR v_biz IN SELECT business_key, level FROM public.team_businesses WHERE team_businesses.team_id = admin_set_bankrupt.team_id LOOP
      DELETE FROM public.team_businesses
      WHERE team_businesses.team_id = admin_set_bankrupt.team_id
        AND team_businesses.business_key = v_biz.business_key;

      INSERT INTO public.activity_events (
        room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
      ) VALUES (
        v_room_id, team_id, 'BUSINESS_REMOVED', v_biz.business_key, jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'BANKRUPTCY'), note, v_is_correction, auth.uid(), public.app_now()
      );
    END LOOP;
  END IF;

  UPDATE public.teams
  SET is_bankrupt = value,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BANKRUPTCY_SET',
    jsonb_build_object('is_bankrupt', v_curr_bankrupt),
    jsonb_build_object('is_bankrupt', value),
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- admin_set_team_values
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_team_values(
  team_id uuid,
  cash int DEFAULT NULL,
  cv int DEFAULT NULL,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_version int;
  v_curr_cash int;
  v_curr_cv int;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT version, teams.cash, teams.cv
  INTO v_curr_version, v_curr_cash, v_curr_cv
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['CASH_SET', 'CV_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_curr_version,
      'cash', v_curr_cash,
      'cv', v_curr_cv
    ));
  END IF;

  IF cash IS NOT NULL AND (cash < 0 OR cash > public.max_money()) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'cash', cash, 'max', public.max_money()));
  END IF;

  IF cv IS NOT NULL AND (cv < 0 OR cv > public.max_money()) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'cv', cv, 'max', public.max_money()));
  END IF;

  IF (cash IS NULL OR cash = v_curr_cash) AND (cv IS NULL OR cv = v_curr_cv) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  UPDATE public.teams
  SET cash = coalesce(admin_set_team_values.cash, teams.cash),
      cv = coalesce(admin_set_team_values.cv, teams.cv),
      version = version + 1
  WHERE id = team_id;

  IF cash IS NOT NULL AND cash <> v_curr_cash THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, request_id, 'CASH_SET', jsonb_build_object('cash', v_curr_cash), jsonb_build_object('cash', cash), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  IF cv IS NOT NULL AND cv <> v_curr_cv THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, CASE WHEN cash IS NOT NULL AND cash <> v_curr_cash THEN NULL ELSE request_id END, 'CV_SET', jsonb_build_object('cv', v_curr_cv), jsonb_build_object('cv', cv), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- admin_adjust
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_adjust(
  changes jsonb,
  label text,
  note text DEFAULT NULL,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_correction boolean := false;
  v_group_id uuid := gen_random_uuid();
  v_max bigint := public.max_money();
  v_el jsonb;
  v_key text;
  v_txt text;
  v_ids uuid[];
  v_found int;
  v_rooms int;
  v_item jsonb;
  v_team_id uuid;
  v_cash_delta int;
  v_cv_delta int;
  v_exp_ver int;
  v_curr_ver int;
  v_curr_cash int;
  v_curr_cv int;
  v_res_cash int;
  v_res_cv int;
  v_clamped boolean;
  v_first boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Shape validation: nothing below may surface a raw cast error.
  IF changes IS NULL OR jsonb_typeof(changes) <> 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'changes', 'reason', 'expected array of 1..6 items'));
  END IF;

  FOR v_el IN SELECT value FROM jsonb_array_elements(changes) LOOP
    IF jsonb_typeof(v_el) <> 'object'
       OR coalesce(v_el->>'team_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id'));
    END IF;

    FOREACH v_key IN ARRAY ARRAY['cash_delta', 'cv_delta', 'expected_version'] LOOP
      v_txt := v_el->>v_key;
      IF v_txt IS NULL THEN
        IF v_key = 'expected_version' THEN
          PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'reason', 'required'));
        END IF;
        CONTINUE;
      END IF;
      -- Two steps: Postgres does not guarantee OR short-circuit order, so never cast before the regex passes.
      IF jsonb_typeof(v_el->v_key) <> 'number' OR v_txt !~ '^-?[0-9]{1,10}$' THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key));
      END IF;
      IF abs(v_txt::bigint) > v_max OR (v_key = 'expected_version' AND v_txt::bigint < 0) THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'max', v_max));
      END IF;
    END LOOP;
  END LOOP;

  SELECT array_agg((value->>'team_id')::uuid ORDER BY (value->>'team_id')::uuid) INTO v_ids
  FROM jsonb_array_elements(changes);

  IF (SELECT count(DISTINCT x) FROM unnest(v_ids) x) <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'duplicate team'));
  END IF;

  SELECT count(*), count(DISTINCT t.room_id), (array_agg(t.room_id))[1]
  INTO v_found, v_rooms, v_room_id
  FROM public.teams t
  WHERE t.id = ANY (v_ids);

  IF v_found <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_rooms <> 1 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'teams span several rooms'));
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Canonical order: room, then teams ascending id.
  PERFORM 1 FROM public.teams t WHERE t.id = ANY (v_ids) ORDER BY t.id FOR UPDATE;

  IF public.money_replay_check(v_room_id, NULL, request_id, ARRAY['ADJUSTMENT']) THEN
    SELECT coalesce(jsonb_agg(public.get_team_snapshot(ae.team_id) ORDER BY ae.team_id), '[]'::jsonb)
    INTO v_results
    FROM public.activity_events ae
    WHERE ae.group_id = (SELECT g.group_id FROM public.activity_events g WHERE g.request_id = admin_adjust.request_id);
    RETURN v_results;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  -- Phase 1 validation (all-or-nothing)
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);
    v_exp_ver := (v_item->>'expected_version')::int;

    SELECT version, cash, cv INTO v_curr_ver, v_curr_cash, v_curr_cv
    FROM public.teams
    WHERE id = v_team_id;

    IF v_curr_ver <> v_exp_ver THEN
      PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
        'team_id', v_team_id,
        'expected_version', v_exp_ver,
        'current_version', v_curr_ver
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta < 0 THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object(
        'team_id', v_team_id,
        'cash', v_curr_cash,
        'delta', v_cash_delta,
        'shortfall', abs(v_curr_cash::bigint + v_cash_delta)
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'team_id', v_team_id, 'max', v_max));
    END IF;

    IF v_curr_cv::bigint + v_cv_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'team_id', v_team_id, 'max', v_max));
    END IF;
  END LOOP;

  -- Phase 2 execution
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);

    SELECT cash, cv INTO v_curr_cash, v_curr_cv FROM public.teams WHERE id = v_team_id;

    v_res_cash := v_curr_cash + v_cash_delta;
    v_res_cv := v_curr_cv + v_cv_delta;
    v_clamped := false;

    IF v_res_cv < 0 THEN
      v_res_cv := 0;
      v_clamped := true;
    END IF;

    UPDATE public.teams
    SET cash = v_res_cash,
        cv = v_res_cv,
        version = version + 1
    WHERE id = v_team_id;

    INSERT INTO public.activity_events (
      room_id, team_id, group_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      v_group_id,
      CASE WHEN v_first THEN request_id ELSE NULL END,
      'ADJUSTMENT',
      jsonb_build_object('cash', v_curr_cash, 'cv', v_curr_cv),
      jsonb_build_object('cash', v_res_cash, 'cv', v_res_cv, 'cash_delta', v_cash_delta, 'cv_delta', v_cv_delta, 'clamped', v_clamped),
      coalesce(label || ': ', '') || coalesce(note, ''),
      v_is_correction,
      auth.uid(),
      public.app_now()
    );

    v_first := false;
    v_results := v_results || public.get_team_snapshot(v_team_id);
  END LOOP;

  RETURN v_results;
END;
$$;


-- Migration 0019: Join and PIN abuse resistance
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- WHY THE RETURN VALUE CHANGED
-- Through 0018 join_team INSERTed a failed attempt and then RAISEd. A RAISE aborts the transaction, so the
-- INSERT was rolled back: no failure was ever recorded and the throttle never fired (audit finding N1).
-- Failures of kind BAD_CODE_OR_PIN / TEAM_ALREADY_CLAIMED now COMMIT the attempt row and RETURN
--   {"error": "<CODE>"}
-- instead of raising. The client (rpcJoinTeam) turns that payload into the same AppError code, so error
-- codes are unchanged for users. TOO_MANY_ATTEMPTS and NOT_AUTHENTICATED still RAISE (nothing to record).
--
-- THROTTLE (failures in the last 60 s; successes never count)
--   per user : 5   (unchanged)
--   per team : 10  - once tripped, TOO_MANY_ATTEMPTS is returned whatever PIN is sent, so the lockout is no oracle
--   per room : 30
--   unknown room codes, all callers: 60 (hashed bucket; blocks code enumeration)
-- Sizing: six phones that each mistype up to 4 times produce at most 24 failures per room and 4 per team per
-- minute, under every limit. A 4-digit PIN (10,000 values) at 10 guesses/min/team would take ~16 h to
-- exhaust, whatever number of anonymous sessions the attacker mints. Residual risk: someone holding a room
-- code can lock joins for that room for 60 s at a time; organisers can use admin release / wait.
--
-- Lock order (docs/OPERATIONS.md): room (FOR SHARE here, joins only read it) then team (FOR UPDATE).
-- Joins to a TIME_EXPIRED room are still allowed: the dashboard shows the game-over view to a late
-- reconnect, so behaviour is unchanged. Open owner question: whether a first-time claim should be refused.
--
-- PINs stay plaintext in team_secrets on purpose: organisers must read them out. See docs/OPERATIONS.md.

ALTER TABLE public.join_attempts
  ADD COLUMN IF NOT EXISTS room_id uuid,
  ADD COLUMN IF NOT EXISTS code_hash text;

CREATE INDEX IF NOT EXISTS idx_join_attempts_team_time ON public.join_attempts (team_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_join_attempts_user_time ON public.join_attempts (user_id, attempted_at);
CREATE INDEX IF NOT EXISTS idx_join_attempts_room_time ON public.join_attempts (room_id, attempted_at) WHERE success = false;
CREATE INDEX IF NOT EXISTS idx_join_attempts_unknown_code ON public.join_attempts (attempted_at) WHERE success = false AND room_id IS NULL;

CREATE OR REPLACE FUNCTION public.join_team(
  code text,
  slot int,
  pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text := upper(trim(coalesce(code, '')));
  v_pin text := trim(coalesce(pin, ''));
  v_now timestamptz := public.app_now();
  v_window timestamptz := public.app_now() - interval '60 seconds';
  v_room_id uuid;
  v_team_id uuid;
  v_name text;
  v_real_pin text;
  v_first_claim boolean;
BEGIN
  IF v_user_id IS NULL THEN
    PERFORM public.raise_error('NOT_AUTHENTICATED');
  END IF;

  -- Opportunistic retention: bounded so a join never pays for a big cleanup.
  DELETE FROM public.join_attempts
  WHERE id IN (SELECT id FROM public.join_attempts WHERE attempted_at < v_now - interval '1 hour' LIMIT 100);

  IF (SELECT count(*) FROM public.join_attempts WHERE user_id = v_user_id AND success = false AND attempted_at >= v_window) >= 5 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  SELECT id INTO v_room_id
  FROM public.rooms
  WHERE public.rooms.code = v_code
    AND status IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED');

  IF NOT FOUND THEN
    IF (SELECT count(*) FROM public.join_attempts WHERE success = false AND room_id IS NULL AND attempted_at >= v_window) >= 60 THEN
      PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
    END IF;
    INSERT INTO public.join_attempts (user_id, team_id, room_id, code_hash, success, attempted_at)
    VALUES (v_user_id, NULL, NULL, encode(sha256(convert_to(v_code, 'UTF8')), 'hex'), false, v_now);
    RETURN jsonb_build_object('error', 'BAD_CODE_OR_PIN');
  END IF;

  -- Room first (shared), then team: same direction as every writer.
  PERFORM 1 FROM public.rooms WHERE id = v_room_id FOR SHARE;

  IF (SELECT count(*) FROM public.join_attempts WHERE room_id = v_room_id AND success = false AND attempted_at >= v_window) >= 30 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  SELECT id, name INTO v_team_id, v_name
  FROM public.teams
  WHERE room_id = v_room_id AND teams.slot = join_team.slot;

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, room_id, success, attempted_at)
    VALUES (v_user_id, NULL, v_room_id, false, v_now);
    RETURN jsonb_build_object('error', 'BAD_CODE_OR_PIN');
  END IF;

  IF (SELECT count(*) FROM public.join_attempts WHERE team_id = v_team_id AND success = false AND attempted_at >= v_window) >= 10 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  PERFORM 1 FROM public.teams WHERE id = v_team_id FOR UPDATE;

  SELECT join_pin INTO v_real_pin FROM public.team_secrets WHERE team_id = v_team_id;

  IF v_real_pin IS DISTINCT FROM v_pin THEN
    INSERT INTO public.join_attempts (user_id, team_id, room_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, v_room_id, false, v_now);
    RETURN jsonb_build_object('error', 'BAD_CODE_OR_PIN');
  END IF;

  -- The PIN proves the invitation, but must not let a second phone take over a connected slot.
  IF EXISTS (SELECT 1 FROM public.team_claims WHERE team_id = v_team_id AND user_id <> v_user_id) THEN
    INSERT INTO public.join_attempts (user_id, team_id, room_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, v_room_id, false, v_now);
    RETURN jsonb_build_object('error', 'TEAM_ALREADY_CLAIMED');
  END IF;

  v_first_claim := NOT EXISTS (SELECT 1 FROM public.team_claims WHERE team_id = v_team_id);

  BEGIN
    INSERT INTO public.team_claims (user_id, team_id, claimed_at)
    VALUES (v_user_id, v_team_id, v_now)
    ON CONFLICT (user_id, team_id) DO NOTHING;
  EXCEPTION WHEN unique_violation THEN
    -- Defense in depth: the team lock above already serialises claims.
    INSERT INTO public.join_attempts (user_id, team_id, room_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, v_room_id, false, v_now);
    RETURN jsonb_build_object('error', 'TEAM_ALREADY_CLAIMED');
  END;

  INSERT INTO public.join_attempts (user_id, team_id, room_id, success, attempted_at)
  VALUES (v_user_id, v_team_id, v_room_id, true, v_now);

  IF v_first_claim THEN
    INSERT INTO public.activity_events (
      room_id, team_id, type, new, actor_id, created_at
    ) VALUES (
      v_room_id, v_team_id, 'TEAM_CLAIMED',
      jsonb_build_object('slot', slot, 'name', v_name),
      v_user_id, v_now
    );
  END IF;

  RETURN jsonb_build_object('team_id', v_team_id, 'room_id', v_room_id);
END;
$$;

REVOKE ALL ON FUNCTION public.join_team(text, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_team(text, int, text) TO anon, authenticated;


-- Migration 0020: Security surface lock-down
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- 1. N3/N4 (privacy leaks found in the Phase 6 audit):
--    get_team_snapshot and room_standings are SECURITY DEFINER with no caller check and were executable by
--    signed-in players (anonymous sign-in users have role `authenticated`) and, for room_standings, by anon.
--    A player could read any team's cash/CV/businesses by UUID, or the whole leaderboard of their own room
--    during play. Both are internal helpers: only other SECURITY DEFINER functions (running as the owner)
--    call them, so EXECUTE is revoked from anon and authenticated.
-- 2. N2: anon (no session at all) keeps EXECUTE only on what the public pages call:
--    server_time, get_lobby, join_team, get_my_state, plus is_admin, which RLS policies evaluate for every
--    caller. Everything else is revoked, and default privileges stop future functions from being granted
--    to anon automatically.
-- 3. L9: app_now() honours the app.test_now hook only when the SESSION user is postgres or supabase_admin
--    (psql / pgTAP / CLI; on Supabase `postgres` is not a true superuser, so rolsuper cannot be used).
--    PostgREST connects as `authenticator`, so no HTTP caller can move the clock even if a GUC could be set. app_now and raise_error are internal and no longer executable by clients.
--    expire_if_due stays executable by authenticated (see docs/BACKEND_AUDIT.md, L10).

CREATE OR REPLACE FUNCTION public.app_now()
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  test_now text;
  app_env text;
BEGIN
  test_now := current_setting('app.test_now', true);
  app_env := current_setting('app.env', true);
  IF test_now IS NOT NULL AND test_now <> '' AND app_env = 'test'
     AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN test_now::timestamptz;
  END IF;
  RETURN clock_timestamp();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_team_snapshot(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.room_standings(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.app_now() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.raise_error(text, jsonb) FROM PUBLIC, anon, authenticated;

-- anon allowlist. is_admin must stay: RLS policies call it for every role.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname NOT IN ('server_time', 'get_lobby', 'join_team', 'get_my_state', 'is_admin')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
  END LOOP;
END $$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;


-- Migration 0021: Final business snapshot and single-pass finalize
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- Ranking was checked against docs/SCORING_RULES.md and already matches, so room_standings is unchanged.
--
-- 1. final_result_businesses (append-only, same immutability trigger as final_results) stores each team's
--    businesses at finalization together with the catalog numbers as they were THEN, so history never
--    depends on later business_catalog edits (audit L16). rooms.businesses_snapshotted marks rooms that have
--    one (false for rooms finalized before this migration), so "no rows" and "not captured" stay distinguishable.
-- 2. admin_finalize locks the room, then the room's teams in ascending id (canonical order, so no correction
--    can land between ranking and insert), computes room_standings ONCE and uses that single result for the
--    tie check, the final_results insert, the winner and the return value. Replay and error codes are as in 0017.
-- 3. get_history_detail gains `businesses` and `snapshot_available`; existing keys are unchanged.

ALTER TABLE public.rooms ADD COLUMN businesses_snapshotted boolean NOT NULL DEFAULT false;

CREATE TABLE public.final_result_businesses (
  room_id uuid NOT NULL REFERENCES public.rooms(id),
  team_id uuid NOT NULL REFERENCES public.teams(id),
  business_key text NOT NULL,
  name text NOT NULL,
  level smallint NOT NULL,
  cost int NOT NULL,
  initial_cv int NOT NULL,
  u1_cost int NOT NULL,
  u2_cost int NOT NULL,
  u1_cv int NOT NULL,
  u2_cv int NOT NULL,
  PRIMARY KEY (room_id, team_id, business_key)
);
ALTER TABLE public.final_result_businesses ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER trg_final_result_businesses_immutable
BEFORE UPDATE OR DELETE ON public.final_result_businesses
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_immutable_table();

-- Supabase default privileges hand every client role ALL rights (incl. TRUNCATE, which skips RLS and row
-- triggers) on a new table. Take them back, then grant SELECT only. Defaults are fixed so a future table
-- cannot repeat this: new tables get no client privileges until a migration grants them explicitly.
REVOKE ALL ON public.final_result_businesses FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.final_result_businesses TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;

CREATE POLICY "Admins can select all final result businesses"
  ON public.final_result_businesses
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "Claimed users can select own final result businesses"
  ON public.final_result_businesses
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.team_claims tc
      WHERE tc.team_id = final_result_businesses.team_id
        AND tc.user_id = (SELECT auth.uid())
    )
  );

CREATE OR REPLACE FUNCTION public.admin_finalize(p_room_id uuid, request_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_tied_ids jsonb;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_FINALIZED') THEN
    SELECT winner_team_id INTO v_winner_id FROM public.rooms WHERE id = p_room_id;
    SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
    INTO v_standings
    FROM public.room_standings(p_room_id) s;
    RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
  END IF;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Canonical order: room (held), then teams ascending id. No correction can interleave from here on.
  PERFORM 1 FROM public.teams WHERE room_id = p_room_id ORDER BY id ASC FOR UPDATE;

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  SELECT jsonb_agg(e->'team_id') INTO v_tied_ids
  FROM jsonb_array_elements(v_standings) e
  WHERE (e->>'tie_unresolved')::boolean;

  IF v_tied_ids IS NOT NULL THEN
    PERFORM public.raise_error('UNRESOLVED_TIE', jsonb_build_object('tied_team_ids', v_tied_ids));
  END IF;

  INSERT INTO public.final_results (room_id, team_id, rank, cv, cash, business_count, is_bankrupt)
  SELECT p_room_id, (e->>'team_id')::uuid, (e->>'rank')::smallint, (e->>'cv')::int, (e->>'cash')::int,
         (e->>'business_count')::smallint, (e->>'is_bankrupt')::boolean
  FROM jsonb_array_elements(v_standings) e;

  INSERT INTO public.final_result_businesses (
    room_id, team_id, business_key, name, level, cost, initial_cv, u1_cost, u2_cost, u1_cv, u2_cv
  )
  SELECT p_room_id, tb.team_id, tb.business_key, bc.name, tb.level, bc.cost, bc.initial_cv,
         bc.u1_cost, bc.u2_cost, bc.u1_cv, bc.u2_cv
  FROM public.team_businesses tb
  JOIN public.teams t ON t.id = tb.team_id
  JOIN public.business_catalog bc ON bc.key = tb.business_key
  WHERE t.room_id = p_room_id;

  SELECT (e->>'team_id')::uuid INTO v_winner_id
  FROM jsonb_array_elements(v_standings) e
  WHERE (e->>'rank')::int = 1 AND NOT (e->>'is_bankrupt')::boolean;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      businesses_snapshotted = true,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    p_room_id, request_id, 'GAME_FINALIZED', 'Match finalized. Leaderboard permanently snapshotted.', auth.uid(), public.app_now()
  );

  RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_finalize(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_finalize(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_history_detail(room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room jsonb;
  v_results jsonb;
  v_events jsonb;
  v_businesses jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT to_jsonb(r.*) INTO v_room
  FROM public.rooms r
  WHERE r.id = room_id AND r.status = 'FINALIZED';

  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', room_id));
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'team_id', fr.team_id,
      'rank', fr.rank,
      'name', t.name,
      'color', t.color,
      'cv', fr.cv,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) ORDER BY fr.rank ASC
  ), '[]'::jsonb) INTO v_results
  FROM public.final_results fr
  JOIN public.teams t ON fr.team_id = t.id
  WHERE fr.room_id = get_history_detail.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ae.id,
      'team_id', ae.team_id,
      'group_id', ae.group_id,
      'type', ae.type,
      'business_key', ae.business_key,
      'prev', ae.prev,
      'new', ae.new,
      'note', ae.note,
      'is_correction', ae.is_correction,
      'created_at', ae.created_at
    ) ORDER BY ae.id DESC
  ), '[]'::jsonb) INTO v_events
  FROM public.activity_events ae
  WHERE ae.room_id = get_history_detail.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'team_id', b.team_id,
      'business_key', b.business_key,
      'name', b.name,
      'level', b.level,
      'cost', b.cost,
      'initial_cv', b.initial_cv,
      'u1_cost', b.u1_cost,
      'u2_cost', b.u2_cost,
      'u1_cv', b.u1_cv,
      'u2_cv', b.u2_cv
    ) ORDER BY b.team_id, b.business_key
  ), '[]'::jsonb) INTO v_businesses
  FROM public.final_result_businesses b
  WHERE b.room_id = get_history_detail.room_id;

  RETURN jsonb_build_object(
    'room', v_room,
    'results', v_results,
    'events', v_events,
    'businesses', v_businesses,
    'snapshot_available', (v_room->>'businesses_snapshotted')::boolean
  );
END;
$$;


-- Migration 0022: Game Accounting CV and Bankruptcy Reconciliation
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- 1. admin_remove_business: When reason = 'CORRECTION', deduct initial_cv and all upgrade CV
--    associated with the removed business (floored at 0).
-- 2. admin_set_bankrupt: When value = true, explicitly set cash = 0 in accordance with rulebook
--    bankruptcy debt exhaustion.
-- 3. admin_set_team_values & admin_adjust: Reject mutations on bankrupt teams with TEAM_BANKRUPT.

CREATE OR REPLACE FUNCTION public.admin_remove_business(
  team_id uuid,
  business_key text,
  reason text,
  credit_resale boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_curr_level smallint;
  v_cost int;
  v_initial_cv int;
  v_u1_cv int;
  v_u2_cv int;
  v_cv_deduction int := 0;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash, t.cv
  INTO v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_REMOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF reason = 'CORRECTION' THEN
    v_is_correction := true;
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash, 'cv', v_cv);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    IF v_cash::bigint + v_cost > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
    END IF;
    v_cash := v_cash + v_cost;
  ELSIF reason = 'CORRECTION' THEN
    SELECT initial_cv, u1_cv, u2_cv INTO v_initial_cv, v_u1_cv, v_u2_cv
    FROM public.business_catalog
    WHERE key = business_key;

    v_cv_deduction := v_initial_cv;
    IF v_curr_level >= 1 THEN
      v_cv_deduction := v_cv_deduction + v_u1_cv;
    END IF;
    IF v_curr_level >= 2 THEN
      v_cv_deduction := v_cv_deduction + v_u2_cv;
    END IF;

    v_cv := greatest(0, v_cv - v_cv_deduction);
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object(
    'business_key', business_key,
    'reason', reason,
    'credit_resale', credit_resale,
    'cash', v_cash,
    'cv', v_cv
  );

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_bankrupt(
  team_id uuid,
  value boolean,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_curr_bankrupt boolean;
  v_curr_cash int;
  v_biz RECORD;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.is_bankrupt, t.cash
  INTO v_curr_ver, v_curr_bankrupt, v_curr_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BANKRUPTCY_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF NOT value AND (note IS NULL OR trim(note) = '') THEN
    PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'undoing_bankruptcy_requires_note'));
  END IF;

  IF value THEN
    -- Liquidate all owned businesses back to the bank
    FOR v_biz IN SELECT business_key, level FROM public.team_businesses WHERE team_businesses.team_id = admin_set_bankrupt.team_id LOOP
      DELETE FROM public.team_businesses
      WHERE team_businesses.team_id = admin_set_bankrupt.team_id
        AND team_businesses.business_key = v_biz.business_key;

      INSERT INTO public.activity_events (
        room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
      ) VALUES (
        v_room_id, team_id, 'BUSINESS_REMOVED', v_biz.business_key, jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'BANKRUPTCY'), note, v_is_correction, auth.uid(), public.app_now()
      );
    END LOOP;

    UPDATE public.teams
    SET cash = 0,
        is_bankrupt = true,
        version = version + 1
    WHERE id = team_id;
  ELSE
    UPDATE public.teams
    SET is_bankrupt = false,
        version = version + 1
    WHERE id = team_id;
  END IF;

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BANKRUPTCY_SET',
    jsonb_build_object('is_bankrupt', v_curr_bankrupt, 'cash', v_curr_cash),
    jsonb_build_object('is_bankrupt', value, 'cash', CASE WHEN value THEN 0 ELSE v_curr_cash END),
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_team_values(
  team_id uuid,
  cash int DEFAULT NULL,
  cv int DEFAULT NULL,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_version int;
  v_curr_cash int;
  v_curr_cv int;
  v_curr_bankrupt boolean;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT version, teams.cash, teams.cv, teams.is_bankrupt
  INTO v_curr_version, v_curr_cash, v_curr_cv, v_curr_bankrupt
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_curr_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['CASH_SET', 'CV_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_curr_version,
      'cash', v_curr_cash,
      'cv', v_curr_cv
    ));
  END IF;

  IF cash IS NOT NULL AND (cash < 0 OR cash > public.max_money()) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
  END IF;

  IF cv IS NOT NULL AND (cv < 0 OR cv > public.max_money()) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'max', public.max_money()));
  END IF;

  IF (cash IS NULL OR cash = v_curr_cash) AND (cv IS NULL OR cv = v_curr_cv) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  UPDATE public.teams
  SET cash = coalesce(admin_set_team_values.cash, teams.cash),
      cv = coalesce(admin_set_team_values.cv, teams.cv),
      version = version + 1
  WHERE id = team_id;

  IF cash IS NOT NULL AND cash <> v_curr_cash THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, request_id, 'CASH_SET', jsonb_build_object('cash', v_curr_cash), jsonb_build_object('cash', cash), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  IF cv IS NOT NULL AND cv <> v_curr_cv THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, CASE WHEN cash IS NOT NULL AND cash <> v_curr_cash THEN NULL ELSE request_id END, 'CV_SET', jsonb_build_object('cv', v_curr_cv), jsonb_build_object('cv', cv), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_adjust(
  changes jsonb,
  label text,
  note text DEFAULT NULL,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_correction boolean := false;
  v_group_id uuid := gen_random_uuid();
  v_max bigint := public.max_money();
  v_el jsonb;
  v_key text;
  v_txt text;
  v_ids uuid[];
  v_found int;
  v_rooms int;
  v_item jsonb;
  v_team_id uuid;
  v_cash_delta int;
  v_cv_delta int;
  v_exp_ver int;
  v_curr_ver int;
  v_curr_cash int;
  v_curr_cv int;
  v_curr_bankrupt boolean;
  v_res_cash int;
  v_res_cv int;
  v_clamped boolean;
  v_first boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Shape validation: nothing below may surface a raw cast error.
  IF changes IS NULL OR jsonb_typeof(changes) <> 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'changes', 'reason', 'expected array of 1..6 items'));
  END IF;

  FOR v_el IN SELECT value FROM jsonb_array_elements(changes) LOOP
    IF jsonb_typeof(v_el) <> 'object'
       OR coalesce(v_el->>'team_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id'));
    END IF;

    FOREACH v_key IN ARRAY ARRAY['cash_delta', 'cv_delta', 'expected_version'] LOOP
      v_txt := v_el->>v_key;
      IF v_txt IS NULL THEN
        IF v_key = 'expected_version' THEN
          PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'reason', 'required'));
        END IF;
        CONTINUE;
      END IF;
      -- Two steps: Postgres does not guarantee OR short-circuit order, so never cast before the regex passes.
      IF jsonb_typeof(v_el->v_key) <> 'number' OR v_txt !~ '^-?[0-9]{1,10}$' THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key));
      END IF;
      IF abs(v_txt::bigint) > v_max OR (v_key = 'expected_version' AND v_txt::bigint < 0) THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'max', v_max));
      END IF;
    END LOOP;
  END LOOP;

  SELECT array_agg((value->>'team_id')::uuid ORDER BY (value->>'team_id')::uuid) INTO v_ids
  FROM jsonb_array_elements(changes);

  IF (SELECT count(DISTINCT x) FROM unnest(v_ids) x) <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'duplicate team'));
  END IF;

  SELECT count(*), count(DISTINCT t.room_id), (array_agg(t.room_id))[1]
  INTO v_found, v_rooms, v_room_id
  FROM public.teams t
  WHERE t.id = ANY (v_ids);

  IF v_found <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_rooms <> 1 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'teams span several rooms'));
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Canonical order: room, then teams ascending id.
  PERFORM 1 FROM public.teams t WHERE t.id = ANY (v_ids) ORDER BY t.id FOR UPDATE;

  IF public.money_replay_check(v_room_id, NULL, request_id, ARRAY['ADJUSTMENT']) THEN
    SELECT coalesce(jsonb_agg(public.get_team_snapshot(ae.team_id) ORDER BY ae.team_id), '[]'::jsonb)
    INTO v_results
    FROM public.activity_events ae
    WHERE ae.group_id = (SELECT g.group_id FROM public.activity_events g WHERE g.request_id = admin_adjust.request_id);
    RETURN v_results;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  -- Phase 1 validation (all-or-nothing)
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);
    v_exp_ver := (v_item->>'expected_version')::int;

    SELECT version, cash, cv, is_bankrupt INTO v_curr_ver, v_curr_cash, v_curr_cv, v_curr_bankrupt
    FROM public.teams
    WHERE id = v_team_id;

    IF v_curr_bankrupt THEN
      PERFORM public.raise_error('TEAM_BANKRUPT', jsonb_build_object('team_id', v_team_id));
    END IF;

    IF v_curr_ver <> v_exp_ver THEN
      PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
        'team_id', v_team_id,
        'expected_version', v_exp_ver,
        'current_version', v_curr_ver
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta < 0 THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object(
        'team_id', v_team_id,
        'cash', v_curr_cash,
        'delta', v_cash_delta,
        'shortfall', abs(v_curr_cash::bigint + v_cash_delta)
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'team_id', v_team_id, 'max', v_max));
    END IF;

    IF v_curr_cv::bigint + v_cv_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'team_id', v_team_id, 'max', v_max));
    END IF;
  END LOOP;

  -- Phase 2 execution
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_cv_delta := coalesce((v_item->>'cv_delta')::int, 0);

    SELECT cash, cv INTO v_curr_cash, v_curr_cv FROM public.teams WHERE id = v_team_id;

    v_res_cash := v_curr_cash + v_cash_delta;
    v_res_cv := v_curr_cv + v_cv_delta;
    v_clamped := false;

    IF v_res_cv < 0 THEN
      v_res_cv := 0;
      v_clamped := true;
    END IF;

    UPDATE public.teams
    SET cash = v_res_cash,
        cv = v_res_cv,
        version = version + 1
    WHERE id = v_team_id;

    INSERT INTO public.activity_events (
      room_id,
      team_id,
      group_id,
      request_id,
      type,
      prev,
      new,
      note,
      is_correction,
      actor_id,
      created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      v_group_id,
      CASE WHEN v_first THEN request_id ELSE NULL END,
      'ADJUSTMENT',
      jsonb_build_object('cash', v_curr_cash, 'cv', v_curr_cv),
      jsonb_build_object('cash', v_res_cash, 'cv', v_res_cv, 'cash_delta', v_cash_delta, 'cv_delta', v_cv_delta, 'clamped', v_clamped),
      coalesce(label || ': ', '') || coalesce(note, ''),
      v_is_correction,
      auth.uid(),
      public.app_now()
    );

    v_first := false;
    v_results := v_results || public.get_team_snapshot(v_team_id);
  END LOOP;

  RETURN v_results;
END;
$$;


-- Migration 0023: Total Company Value Ranking Reconciliation
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- Official Notion Rulebook (Sections 3 & 12):
-- Total Company Value = Cash + Company Value.
-- The active team with the highest Total Company Value wins.
-- Tiebreakers:
-- 1. Highest Cash
-- 2. Most Businesses Held
-- 3. Judged 30-Second Physical Pitch

CREATE OR REPLACE FUNCTION public.room_standings(p_room_id uuid)
RETURNS TABLE (
  team_id uuid,
  slot smallint,
  name text,
  rank int,
  is_bankrupt boolean,
  cv int,
  cash int,
  business_count int,
  tiebreak_order smallint,
  tie_unresolved boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH team_biz AS (
    SELECT t.id AS tid, count(tb.id)::int AS b_count
    FROM public.teams t
    LEFT JOIN public.team_businesses tb ON t.id = tb.team_id
    WHERE t.room_id = p_room_id
    GROUP BY t.id
  ),
  base AS (
    SELECT
      t.id AS tid,
      t.slot,
      t.name,
      t.is_bankrupt,
      t.cv,
      t.cash,
      tbz.b_count AS business_count,
      t.tiebreak_order,
      count(*) OVER (PARTITION BY t.is_bankrupt, (t.cv + t.cash), t.cash, tbz.b_count) AS tie_group_size,
      count(t.tiebreak_order) OVER (PARTITION BY t.is_bankrupt, (t.cv + t.cash), t.cash, tbz.b_count) AS count_with_order
    FROM public.teams t
    JOIN team_biz tbz ON t.id = tbz.tid
    WHERE t.room_id = p_room_id
  ),
  tie_distinct AS (
    SELECT
      b.is_bankrupt AS td_bankrupt,
      (b.cv + b.cash) AS td_total_val,
      b.cash        AS td_cash,
      b.business_count AS td_biz,
      count(DISTINCT b.tiebreak_order) AS distinct_orders
    FROM base b
    GROUP BY b.is_bankrupt, (b.cv + b.cash), b.cash, b.business_count
  )
  SELECT
    b.tid AS team_id,
    b.slot,
    b.name,
    row_number() OVER (
      ORDER BY
        b.is_bankrupt ASC,
        (b.cv + b.cash) DESC,
        b.cash DESC,
        b.business_count DESC,
        b.tiebreak_order ASC NULLS LAST,
        b.slot ASC
    )::int AS rank,
    b.is_bankrupt,
    b.cv,
    b.cash,
    b.business_count,
    b.tiebreak_order,
    (b.tie_group_size > 1 AND (b.count_with_order < b.tie_group_size OR td.distinct_orders < b.tie_group_size)) AS tie_unresolved
  FROM base b
  JOIN tie_distinct td
    ON b.is_bankrupt = td.td_bankrupt
   AND (b.cv + b.cash) = td.td_total_val
   AND b.cash = td.td_cash
   AND b.business_count = td.td_biz
  ORDER BY rank ASC;
END;
$$;


-- Migration 0024: Admin Extend Game (10-minute overtime / extra time)
--
-- Enables the host/admin to extend gameplay time by X seconds (default 600s / 10 mins).
-- Works when the room is ACTIVE (adding extra time) or when TIME_EXPIRED (re-activating
-- the room and pushing ends_at into the future).
--
-- 0. Updates activity_events type check constraint to permit GAME_EXTENDED.
-- 1. Updates fn_check_room_status_transition to allow TIME_EXPIRED -> ACTIVE.
-- 2. Creates public.admin_extend_game(p_room_id, p_additional_seconds, request_id).

-- 0. Update activity_events type check constraint to permit GAME_EXTENDED
ALTER TABLE public.activity_events DROP CONSTRAINT IF EXISTS activity_events_type_check;
ALTER TABLE public.activity_events ADD CONSTRAINT activity_events_type_check CHECK (type IN (
  'ROOM_CREATED',
  'TEAM_CONFIGURED',
  'LOBBY_OPENED',
  'TEAM_CLAIMED',
  'TEAM_RELEASED',
  'GAME_STARTED',
  'CASH_SET',
  'CV_SET',
  'ADJUSTMENT',
  'BUSINESS_ADDED',
  'BUSINESS_LEVEL_SET',
  'BUSINESS_REMOVED',
  'BANKRUPTCY_SET',
  'TIEBREAK_SET',
  'TIME_EXPIRED',
  'GAME_FINALIZED',
  'GAME_ABORTED',
  'GAME_EXTENDED'
));

-- 1. Update room status transition trigger
CREATE OR REPLACE FUNCTION public.fn_check_room_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    IF NOT (
      (OLD.status = 'CREATED' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'LOBBY' AND NEW.status = 'ACTIVE') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'TIME_EXPIRED') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'FINALIZED') OR
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'ACTIVE') -- Host extended game into extra time
    ) THEN
      RAISE EXCEPTION 'INVALID_TRANSITION';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 2. Admin Extend Game Function
CREATE OR REPLACE FUNCTION public.admin_extend_game(
  p_room_id uuid,
  p_additional_seconds int DEFAULT 600,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_ends_at timestamptz;
  v_duration int;
  v_new_ends_at timestamptz;
  v_mins int;
BEGIN
  -- Admin authorization check
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Validate additional seconds
  IF p_additional_seconds IS NULL OR p_additional_seconds <= 0 THEN
    p_additional_seconds := 600;
  END IF;

  v_mins := p_additional_seconds / 60;

  -- Idempotency check: if this request_id was already recorded, return current room
  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_EXTENDED') THEN
    SELECT status, ends_at, duration_seconds INTO v_status, v_ends_at, v_duration
    FROM public.rooms WHERE id = p_room_id;
    RETURN jsonb_build_object(
      'room_id', p_room_id,
      'status', v_status,
      'ends_at', v_ends_at,
      'duration_seconds', v_duration
    );
  END IF;

  -- Lock room row
  SELECT status, ends_at, duration_seconds INTO v_status, v_ends_at, v_duration
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  -- Disallow extending finalized games or unstarted lobbies
  IF v_status = 'FINALIZED' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('room_id', p_room_id, 'status', v_status));
  END IF;

  IF v_status NOT IN ('ACTIVE', 'TIME_EXPIRED') THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'ACTIVE'));
  END IF;

  -- Calculate new ends_at
  IF v_status = 'TIME_EXPIRED' OR v_ends_at IS NULL OR public.app_now() >= v_ends_at THEN
    v_new_ends_at := public.app_now() + (p_additional_seconds || ' seconds')::interval;
  ELSE
    v_new_ends_at := v_ends_at + (p_additional_seconds || ' seconds')::interval;
  END IF;

  -- Update rooms row
  UPDATE public.rooms
  SET status = 'ACTIVE',
      ends_at = v_new_ends_at,
      duration_seconds = duration_seconds + p_additional_seconds
  WHERE id = p_room_id;

  -- Insert activity event
  INSERT INTO public.activity_events (
    room_id,
    request_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    p_room_id,
    request_id,
    'GAME_EXTENDED',
    'Host added ' || v_mins::text || ' minutes extra time. Match clock extended.',
    auth.uid(),
    public.app_now()
  );

  RETURN jsonb_build_object(
    'room_id', p_room_id,
    'status', 'ACTIVE',
    'ends_at', v_new_ends_at,
    'duration_seconds', v_duration + p_additional_seconds
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_extend_game(uuid, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_extend_game(uuid, int, uuid) TO authenticated;


-- Migration 0025: Admin Cancel / Discard Room & Player Leave Team
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- Enables:
-- 1. Host/admin to cancel or discard an unstarted (CREATED, LOBBY) or accidental ACTIVE room.
-- 2. Players to voluntarily disconnect from a team slot during LOBBY if they joined by mistake.
--
-- Updates fn_check_room_status_transition to allow CREATED -> FINALIZED, LOBBY -> FINALIZED, and ACTIVE -> FINALIZED.

-- 1. Update room status transition trigger
CREATE OR REPLACE FUNCTION public.fn_check_room_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    IF NOT (
      (OLD.status = 'CREATED' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'CREATED' AND NEW.status = 'FINALIZED') OR -- Discard during setup
      (OLD.status = 'LOBBY' AND NEW.status = 'ACTIVE') OR
      (OLD.status = 'LOBBY' AND NEW.status = 'FINALIZED') OR   -- Cancel during lobby
      (OLD.status = 'ACTIVE' AND NEW.status = 'TIME_EXPIRED') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'LOBBY') OR
      (OLD.status = 'ACTIVE' AND NEW.status = 'FINALIZED') OR  -- Early cancel during active
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'FINALIZED') OR
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'ACTIVE')  -- Host extended game into extra time
    ) THEN
      RAISE EXCEPTION 'INVALID_TRANSITION';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 2. Admin Cancel Room Function
CREATE OR REPLACE FUNCTION public.admin_cancel_room(
  p_room_id uuid,
  note text DEFAULT 'Cancelled by organizer',
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status = 'FINALIZED' THEN
    PERFORM public.raise_error('ROOM_FINALIZED');
  END IF;

  -- Disconnect all claimed sessions for this room
  DELETE FROM public.team_claims
  WHERE team_id IN (SELECT id FROM public.teams WHERE room_id = p_room_id);

  -- Transition room to FINALIZED
  UPDATE public.rooms
  SET status = 'FINALIZED',
      ended_at = coalesce(ended_at, public.app_now())
  WHERE id = p_room_id;

  -- Record audit event
  INSERT INTO public.activity_events (room_id, type, note, is_correction, created_at)
  VALUES (p_room_id, 'GAME_FINALIZED', coalesce(note, 'Match cancelled by organizer'), true, public.app_now());

  RETURN jsonb_build_object('room_id', p_room_id, 'status', 'FINALIZED', 'cancelled', true);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_cancel_room(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_cancel_room(uuid, text, uuid) TO authenticated;

-- 3. Player Leave Team Function (LOBBY only)
CREATE OR REPLACE FUNCTION public.leave_team()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_room_id uuid;
  v_status public.room_status;
  v_slot int;
  v_name text;
BEGIN
  IF v_user_id IS NULL THEN
    PERFORM public.raise_error('NOT_AUTHENTICATED');
  END IF;

  SELECT tc.team_id, t.room_id, t.slot, t.name, r.status
  INTO v_team_id, v_room_id, v_slot, v_name, v_status
  FROM public.team_claims tc
  JOIN public.teams t ON tc.team_id = t.id
  JOIN public.rooms r ON t.room_id = r.id
  WHERE tc.user_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'message', 'No active team claim');
  END IF;

  -- Only allow voluntary departure during LOBBY stage
  IF v_status <> 'LOBBY' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  DELETE FROM public.team_claims WHERE user_id = v_user_id;

  INSERT INTO public.activity_events (
    room_id, team_id, type, note, actor_id, created_at
  ) VALUES (
    v_room_id, v_team_id, 'TEAM_RELEASED',
    'Player voluntarily disconnected from Slot #' || v_slot || ' (' || v_name || ')',
    v_user_id, public.app_now()
  );

  RETURN jsonb_build_object('success', true, 'team_id', v_team_id, 'slot', v_slot);
END;
$$;

REVOKE ALL ON FUNCTION public.leave_team() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_team() TO authenticated;


-- Migration 0026: Admin Multi-Tenancy (Dedicated Admin Spaces) & Match Isolation
-- STARTUPOLY Live Scoreboard & Game Management System
--
-- Enables:
-- 1. Multiple independent administrators (e.g. 3 concurrent event organizers) to each
--    manage their own distinct matches without collision or blocking.
-- 2. Scopes NON_FINAL_ROOM_EXISTS check in admin_create_room to the calling admin's user ID.
-- 3. Scopes list_history() to the calling admin's created rooms.
-- 4. Ensures admin_cancel_room enforces room ownership when created_by is set.

-- 1. Update admin_create_room to isolate active room check per admin
CREATE OR REPLACE FUNCTION public.admin_create_room(
  team_count int,
  teams jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_code text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_team_id uuid;
  v_team_elem jsonb;
  v_name text;
  v_color text;
  v_pin text;
  i int;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Multi-admin workspace isolation: check if THIS admin already has an active room
  IF EXISTS (
    SELECT 1 FROM public.rooms
    WHERE status <> 'FINALIZED'
      AND (created_by = auth.uid() OR (created_by IS NULL AND auth.uid() IS NULL))
  ) THEN
    PERFORM public.raise_error('NON_FINAL_ROOM_EXISTS');
  END IF;

  IF team_count NOT BETWEEN 5 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('team_count', team_count));
  END IF;

  IF jsonb_array_length(teams) <> team_count THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('teams_length', jsonb_array_length(teams)));
  END IF;

  -- Generate unique 6-character room code across all non-finalized rooms
  LOOP
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, floor(random() * 32)::int + 1, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.rooms WHERE code = v_code AND status <> 'FINALIZED');
  END LOOP;

  INSERT INTO public.rooms (code, status, team_count, created_by, created_at)
  VALUES (v_code, 'CREATED', team_count, auth.uid(), public.app_now())
  RETURNING id INTO v_room_id;

  -- Insert teams & unique PINs
  FOR i IN 1..team_count LOOP
    v_team_elem := teams->(i - 1);
    v_name := trim(coalesce(v_team_elem->>'name', ''));
    v_color := upper(trim(coalesce(v_team_elem->>'color', '')));

    IF char_length(v_name) < 1 OR char_length(v_name) > 30 OR v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('slot', i, 'name', v_name, 'color', v_color));
    END IF;

    -- Generate random 4-digit PIN unique within this room
    LOOP
      v_pin := lpad(floor(random() * 10000)::text, 4, '0');
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.team_secrets ts
        JOIN public.teams t ON ts.team_id = t.id
        WHERE t.room_id = v_room_id AND ts.join_pin = v_pin
      );
    END LOOP;

    INSERT INTO public.teams (room_id, slot, name, color, cash, cv, version, created_at)
    VALUES (v_room_id, i, v_name, v_color, 1000, 0, 0, public.app_now())
    RETURNING id INTO v_team_id;

    INSERT INTO public.team_secrets (team_id, join_pin)
    VALUES (v_team_id, v_pin);
  END LOOP;

  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    'ROOM_CREATED',
    'Room created with ' || team_count::text || ' teams by admin workspace ' || coalesce(auth.uid()::text, 'system'),
    auth.uid(),
    public.app_now()
  );

  SELECT jsonb_build_object(
    'id', r.id,
    'code', r.code,
    'status', r.status,
    'team_count', r.team_count,
    'created_at', r.created_at,
    'teams', coalesce(jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'slot', t.slot,
        'name', t.name,
        'color', t.color,
        'pin', ts.join_pin
      ) ORDER BY t.slot
    ), '[]'::jsonb)
  ) INTO v_room
  FROM public.rooms r
  JOIN public.teams t ON r.id = t.room_id
  JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE r.id = v_room_id
  GROUP BY r.id, r.code, r.status, r.team_count, r.created_at;

  RETURN v_room;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_room(int, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_room(int, jsonb) TO authenticated;

-- 2. Update list_history() to show matches belonging to this admin
CREATE OR REPLACE FUNCTION public.list_history()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_history jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'room_id', r.id,
      'code', r.code,
      'created_at', r.created_at,
      'finalized_at', r.finalized_at,
      'winner_name', w.name,
      'winner_color', w.color,
      'team_count', r.team_count
    ) ORDER BY r.finalized_at DESC NULLS LAST
  ), '[]'::jsonb) INTO v_history
  FROM public.rooms r
  LEFT JOIN public.teams w ON r.winner_team_id = w.id
  WHERE r.status = 'FINALIZED'
    AND (r.created_by = auth.uid() OR r.created_by IS NULL OR auth.uid() IS NULL);

  RETURN v_history;
END;
$$;

REVOKE ALL ON FUNCTION public.list_history() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_history() TO authenticated;

-- 3. Update admin_cancel_room to protect against cross-admin cancellation
CREATE OR REPLACE FUNCTION public.admin_cancel_room(
  p_room_id uuid,
  note text DEFAULT 'Cancelled by organizer',
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status public.room_status;
  v_created_by uuid;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status, created_by INTO v_status, v_created_by
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_created_by IS NOT NULL AND auth.uid() IS NOT NULL AND v_created_by <> auth.uid() THEN
    PERFORM public.raise_error('NOT_ROOM_OWNER');
  END IF;

  IF v_status = 'FINALIZED' THEN
    PERFORM public.raise_error('ROOM_FINALIZED');
  END IF;

  -- Disconnect all claimed sessions for this room
  DELETE FROM public.team_claims
  WHERE team_id IN (SELECT id FROM public.teams WHERE room_id = p_room_id);

  -- Transition room to FINALIZED
  UPDATE public.rooms
  SET status = 'FINALIZED',
      ended_at = coalesce(ended_at, public.app_now())
  WHERE id = p_room_id;

  -- Record audit event
  INSERT INTO public.activity_events (room_id, type, note, is_correction, created_at)
  VALUES (p_room_id, 'GAME_FINALIZED', coalesce(note, 'Match cancelled by organizer'), true, public.app_now());

  RETURN jsonb_build_object('room_id', p_room_id, 'status', 'FINALIZED', 'cancelled', true);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_cancel_room(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_cancel_room(uuid, text, uuid) TO authenticated;


-- Migration 0027: Admin live-board positions
--
-- Positions are organizer-only state for the physical board. They never reach
-- player phones, but are persisted so a refreshed admin laptop retains the
-- exact location of every team token.

ALTER TABLE public.teams
  ADD COLUMN board_position smallint NOT NULL DEFAULT 0
  CHECK (board_position BETWEEN 0 AND 23);

ALTER TABLE public.activity_events DROP CONSTRAINT IF EXISTS activity_events_type_check;
ALTER TABLE public.activity_events ADD CONSTRAINT activity_events_type_check CHECK (type IN (
  'ROOM_CREATED', 'TEAM_CONFIGURED', 'LOBBY_OPENED', 'TEAM_CLAIMED', 'TEAM_RELEASED',
  'GAME_STARTED', 'CASH_SET', 'CV_SET', 'ADJUSTMENT', 'BUSINESS_ADDED',
  'BUSINESS_LEVEL_SET', 'BUSINESS_REMOVED', 'BANKRUPTCY_SET', 'TIEBREAK_SET',
  'TIME_EXPIRED', 'GAME_FINALIZED', 'GAME_ABORTED', 'GAME_EXTENDED', 'TEAM_MOVED'
));

CREATE OR REPLACE FUNCTION public.admin_move_team(
  team_id uuid,
  steps smallint,
  expected_version int,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_position smallint;
  v_version int;
  v_next_position smallint;
  v_passed_start boolean;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF steps IS NULL OR steps NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'steps'));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;
  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT board_position, version INTO v_position, v_version
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['TEAM_MOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_version,
      'board_position', v_position
    ));
  END IF;

  v_next_position := ((v_position + steps) % 24)::smallint;
  v_passed_start := v_position + steps >= 24;

  UPDATE public.teams
  SET board_position = v_next_position,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id, team_id, request_id, type, prev, new, note, actor_id, created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'TEAM_MOVED',
    jsonb_build_object('board_position', v_position),
    jsonb_build_object('board_position', v_next_position, 'steps', steps, 'passed_start', v_passed_start),
    format('Moved %s space%s to board space #%s%s.', steps, CASE WHEN steps = 1 THEN '' ELSE 's' END, v_next_position, CASE WHEN v_passed_start THEN ' and passed START' ELSE '' END),
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_move_team(uuid, smallint, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_move_team(uuid, smallint, int, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_admin_snapshot(room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room jsonb;
  v_teams jsonb;
  v_events jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(room_id);

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'slot', t.slot, 'name', t.name, 'color', t.color,
    'cash', t.cash, 'cv', t.cv, 'board_position', t.board_position,
    'is_bankrupt', t.is_bankrupt, 'version', t.version, 'tiebreak_order', t.tiebreak_order,
    'claimed', EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id),
    'pin', ts.join_pin,
    'businesses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'business_key', tb.business_key, 'name', bc.name, 'level', tb.level,
        'cost', bc.cost, 'initial_cv', bc.initial_cv
      ) ORDER BY bc.sort_order)
      FROM public.team_businesses tb JOIN public.business_catalog bc ON tb.business_key = bc.key
      WHERE tb.team_id = t.id
    ), '[]'::jsonb)
  ) ORDER BY t.slot), '[]'::jsonb) INTO v_teams
  FROM public.teams t LEFT JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE t.room_id = get_admin_snapshot.room_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', ae.id, 'team_id', ae.team_id, 'group_id', ae.group_id, 'type', ae.type,
    'business_key', ae.business_key, 'prev', ae.prev, 'new', ae.new, 'note', ae.note,
    'is_correction', ae.is_correction, 'created_at', ae.created_at
  ) ORDER BY ae.id DESC), '[]'::jsonb) INTO v_events
  FROM (SELECT * FROM public.activity_events WHERE public.activity_events.room_id = get_admin_snapshot.room_id ORDER BY id DESC LIMIT 200) ae;

  RETURN jsonb_build_object('room', v_room, 'server_now', public.app_now(), 'teams', v_teams, 'events', v_events);
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_snapshot(uuid) TO authenticated;

-- Returning an active match to the lobby also returns every tracked token to START.
CREATE OR REPLACE FUNCTION public.reset_board_positions_after_abort()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type = 'GAME_ABORTED' THEN
    UPDATE public.teams SET board_position = 0 WHERE room_id = NEW.room_id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_board_positions_after_abort() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER reset_board_positions_after_abort
AFTER INSERT ON public.activity_events
FOR EACH ROW EXECUTE FUNCTION public.reset_board_positions_after_abort();


-- Rulebook alignment: upgrade costs per the approved table and a 2-business cap per team.
-- Forward-only. Teams already holding 3 businesses keep them but cannot add more.

UPDATE public.business_catalog AS c
SET u1_cost = v.u1, u2_cost = v.u2
FROM (VALUES
  ('edtech', 100, 150),
  ('saas', 150, 200), ('ecommerce', 150, 200), ('devtools', 150, 200),
  ('fintech', 200, 250), ('healthtech', 200, 250), ('cybersecurity', 200, 250),
  ('ai_deeptech', 250, 300), ('cleantech', 250, 300), ('robotics', 250, 300)
) AS v(key, u1, u2)
WHERE c.key = v.key;

CREATE OR REPLACE FUNCTION public.fn_check_business_cap()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (SELECT count(*) FROM public.team_businesses WHERE team_id = NEW.team_id) >= 2 THEN
    RAISE EXCEPTION 'BUSINESS_CAP';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_add_business(
  team_id uuid,
  business_key text,
  apply_purchase boolean DEFAULT true,
  expected_version int DEFAULT 0,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cv int;
  v_cost int;
  v_initial_cv int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash, t.cv
  INTO v_is_bankrupt, v_curr_ver, v_cash, v_cv
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_ADDED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 2 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, initial_cv INTO v_cost, v_initial_cv
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key);

  IF apply_purchase THEN
    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
    IF v_cv::bigint + v_initial_cv > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv', 'max', public.max_money()));
    END IF;
    v_cv := v_cv + v_initial_cv;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'cv', v_cv, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;


-- Remove Company Value (CV) from the active system and replace the ranking.
-- Owner decisions: D1 (ranking), D4 (no CORRECTION-removal deduction), D8 (stored CV data removed).
-- Ranking: cash, then total original purchase cost of owned businesses, then total upgrades; equal teams share a rank.
-- Forward-only. Historical activity_events keep their stored JSON (and the CV_SET / TIEBREAK_SET event types stay
-- valid) so the audit trail is intact; nothing reads them for game behaviour.
-- Deploy the database and the app together: RPC signatures and payloads change.

DROP FUNCTION IF EXISTS public.admin_set_tiebreak(uuid, uuid[], text);
DROP FUNCTION IF EXISTS public.room_standings(uuid);

CREATE FUNCTION public.room_standings(p_room_id uuid)
RETURNS TABLE(team_id uuid, slot smallint, name text, rank integer, is_bankrupt boolean, cash integer,
              business_count integer, business_cost integer, upgrade_count integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT t.id AS tid, t.slot, t.name, t.is_bankrupt, t.cash,
           count(tb.id)::int AS business_count,
           coalesce(sum(bc.cost), 0)::int AS business_cost,
           coalesce(sum(tb.level), 0)::int AS upgrade_count
    FROM public.teams t
    LEFT JOIN public.team_businesses tb ON tb.team_id = t.id
    LEFT JOIN public.business_catalog bc ON bc.key = tb.business_key
    WHERE t.room_id = p_room_id
    GROUP BY t.id
  )
  SELECT b.tid, b.slot, b.name,
         (rank() OVER (ORDER BY b.is_bankrupt ASC, b.cash DESC, b.business_cost DESC, b.upgrade_count DESC))::int,
         b.is_bankrupt, b.cash, b.business_count, b.business_cost, b.upgrade_count
  FROM base b
  ORDER BY 4 ASC, b.slot ASC;
$function$;

REVOKE ALL ON FUNCTION public.room_standings(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_standings(p_room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  RETURN jsonb_build_object('standings', v_standings);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_finalize(p_room_id uuid, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_FINALIZED') THEN
    SELECT winner_team_id INTO v_winner_id FROM public.rooms WHERE id = p_room_id;
    SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
    INTO v_standings
    FROM public.room_standings(p_room_id) s;
    RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
  END IF;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Canonical order: room (held), then teams ascending id. No correction can interleave from here on.
  PERFORM 1 FROM public.teams WHERE room_id = p_room_id ORDER BY id ASC FOR UPDATE;

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  INSERT INTO public.final_results (room_id, team_id, rank, cash, business_count, is_bankrupt)
  SELECT p_room_id, (e->>'team_id')::uuid, (e->>'rank')::smallint, (e->>'cash')::int,
         (e->>'business_count')::smallint, (e->>'is_bankrupt')::boolean
  FROM jsonb_array_elements(v_standings) e;

  INSERT INTO public.final_result_businesses (
    room_id, team_id, business_key, name, level, cost, u1_cost, u2_cost
  )
  SELECT p_room_id, tb.team_id, tb.business_key, bc.name, tb.level, bc.cost,
         bc.u1_cost, bc.u2_cost
  FROM public.team_businesses tb
  JOIN public.teams t ON t.id = tb.team_id
  JOIN public.business_catalog bc ON bc.key = tb.business_key
  WHERE t.room_id = p_room_id;

  -- Teams that tie on every criterion share rank 1: then there is no single winner.
  SELECT CASE WHEN count(*) = 1 THEN min(e->>'team_id')::uuid END INTO v_winner_id
  FROM jsonb_array_elements(v_standings) e
  WHERE (e->>'rank')::int = 1 AND NOT (e->>'is_bankrupt')::boolean;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      businesses_snapshotted = true,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    p_room_id, request_id, 'GAME_FINALIZED', 'Match finalized. Leaderboard permanently snapshotted.', auth.uid(), public.app_now()
  );

  RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_set_team_values(uuid, integer, integer, integer, uuid, text);

CREATE FUNCTION public.admin_set_team_values(team_id uuid, cash integer DEFAULT NULL::integer, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_version int;
  v_curr_cash int;
  v_curr_bankrupt boolean;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT version, teams.cash, teams.is_bankrupt
  INTO v_curr_version, v_curr_cash, v_curr_bankrupt
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_curr_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['CASH_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_curr_version,
      'cash', v_curr_cash
    ));
  END IF;

  IF cash IS NOT NULL AND (cash < 0 OR cash > public.max_money()) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
  END IF;

  IF cash IS NULL OR cash = v_curr_cash THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  UPDATE public.teams
  SET cash = coalesce(admin_set_team_values.cash, teams.cash),
      version = version + 1
  WHERE id = team_id;

  IF cash IS NOT NULL AND cash <> v_curr_cash THEN
    INSERT INTO public.activity_events (
      room_id, team_id, request_id, type, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      v_room_id, team_id, request_id, 'CASH_SET', jsonb_build_object('cash', v_curr_cash), jsonb_build_object('cash', cash), note, v_is_correction, auth.uid(), public.app_now()
    );
  END IF;

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_team_values(uuid, integer, integer, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_team_values(uuid, integer, integer, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_adjust(changes jsonb, label text, note text DEFAULT NULL::text, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_correction boolean := false;
  v_group_id uuid := gen_random_uuid();
  v_max bigint := public.max_money();
  v_el jsonb;
  v_key text;
  v_txt text;
  v_ids uuid[];
  v_found int;
  v_rooms int;
  v_item jsonb;
  v_team_id uuid;
  v_cash_delta int;
  v_exp_ver int;
  v_curr_ver int;
  v_curr_cash int;
  v_curr_bankrupt boolean;
  v_res_cash int;
  v_first boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Shape validation: nothing below may surface a raw cast error.
  IF changes IS NULL OR jsonb_typeof(changes) <> 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'changes', 'reason', 'expected array of 1..6 items'));
  END IF;

  FOR v_el IN SELECT value FROM jsonb_array_elements(changes) LOOP
    IF jsonb_typeof(v_el) <> 'object'
       OR coalesce(v_el->>'team_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id'));
    END IF;

    IF v_el ? 'cv_delta' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv_delta', 'reason', 'unsupported'));
    END IF;

    FOREACH v_key IN ARRAY ARRAY['cash_delta', 'expected_version'] LOOP
      v_txt := v_el->>v_key;
      IF v_txt IS NULL THEN
        IF v_key = 'expected_version' THEN
          PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'reason', 'required'));
        END IF;
        CONTINUE;
      END IF;
      -- Two steps: Postgres does not guarantee OR short-circuit order, so never cast before the regex passes.
      IF jsonb_typeof(v_el->v_key) <> 'number' OR v_txt !~ '^-?[0-9]{1,10}$' THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key));
      END IF;
      IF abs(v_txt::bigint) > v_max OR (v_key = 'expected_version' AND v_txt::bigint < 0) THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'max', v_max));
      END IF;
    END LOOP;
  END LOOP;

  SELECT array_agg((value->>'team_id')::uuid ORDER BY (value->>'team_id')::uuid) INTO v_ids
  FROM jsonb_array_elements(changes);

  IF (SELECT count(DISTINCT x) FROM unnest(v_ids) x) <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'duplicate team'));
  END IF;

  SELECT count(*), count(DISTINCT t.room_id), (array_agg(t.room_id))[1]
  INTO v_found, v_rooms, v_room_id
  FROM public.teams t
  WHERE t.id = ANY (v_ids);

  IF v_found <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_rooms <> 1 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'teams span several rooms'));
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Canonical order: room, then teams ascending id.
  PERFORM 1 FROM public.teams t WHERE t.id = ANY (v_ids) ORDER BY t.id FOR UPDATE;

  IF public.money_replay_check(v_room_id, NULL, request_id, ARRAY['ADJUSTMENT']) THEN
    SELECT coalesce(jsonb_agg(public.get_team_snapshot(ae.team_id) ORDER BY ae.team_id), '[]'::jsonb)
    INTO v_results
    FROM public.activity_events ae
    WHERE ae.group_id = (SELECT g.group_id FROM public.activity_events g WHERE g.request_id = admin_adjust.request_id);
    RETURN v_results;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  -- Phase 1 validation (all-or-nothing)
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_exp_ver := (v_item->>'expected_version')::int;

    SELECT version, cash, is_bankrupt INTO v_curr_ver, v_curr_cash, v_curr_bankrupt
    FROM public.teams
    WHERE id = v_team_id;

    IF v_curr_bankrupt THEN
      PERFORM public.raise_error('TEAM_BANKRUPT', jsonb_build_object('team_id', v_team_id));
    END IF;

    IF v_curr_ver <> v_exp_ver THEN
      PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
        'team_id', v_team_id,
        'expected_version', v_exp_ver,
        'current_version', v_curr_ver
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta < 0 THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object(
        'team_id', v_team_id,
        'cash', v_curr_cash,
        'delta', v_cash_delta,
        'shortfall', abs(v_curr_cash::bigint + v_cash_delta)
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'team_id', v_team_id, 'max', v_max));
    END IF;
  END LOOP;

  -- Phase 2 execution
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);

    SELECT cash INTO v_curr_cash FROM public.teams WHERE id = v_team_id;

    v_res_cash := v_curr_cash + v_cash_delta;

    UPDATE public.teams
    SET cash = v_res_cash,
        version = version + 1
    WHERE id = v_team_id;

    INSERT INTO public.activity_events (
      room_id,
      team_id,
      group_id,
      request_id,
      type,
      prev,
      new,
      note,
      is_correction,
      actor_id,
      created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      v_group_id,
      CASE WHEN v_first THEN request_id ELSE NULL END,
      'ADJUSTMENT',
      jsonb_build_object('cash', v_curr_cash),
      jsonb_build_object('cash', v_res_cash, 'cash_delta', v_cash_delta),
      coalesce(label || ': ', '') || coalesce(note, ''),
      v_is_correction,
      auth.uid(),
      public.app_now()
    );

    v_first := false;
    v_results := v_results || public.get_team_snapshot(v_team_id);
  END LOOP;

  RETURN v_results;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_business(team_id uuid, business_key text, apply_purchase boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash
  INTO v_is_bankrupt, v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_ADDED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 2 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost INTO v_cost
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'business_key', business_key);

  IF apply_purchase THEN
    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_business_level(team_id uuid, business_key text, new_level smallint, apply_upgrade boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash
  INTO v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_LEVEL_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash);

  IF apply_upgrade THEN
    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_remove_business(team_id uuid, business_key text, reason text, credit_resale boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash
  INTO v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_REMOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF reason = 'CORRECTION' THEN
    v_is_correction := true;
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    IF v_cash::bigint + v_cost > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
    END IF;
    v_cash := v_cash + v_cost;
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object(
    'business_key', business_key,
    'reason', reason,
    'credit_resale', credit_resale,
    'cash', v_cash
  );

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_abort_game(p_room_id uuid, note text DEFAULT NULL::text, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_room jsonb;
  v_biz RECORD;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF note IS NULL OR trim(note) = '' THEN
    PERFORM public.raise_error('NOTE_REQUIRED');
  END IF;

  -- Flip a passed deadline to TIME_EXPIRED first (takes the room lock).
  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_ABORTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
    RETURN v_room;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('ROOM_ALREADY_EXPIRED', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  -- Lock teams in deterministic ID order to prevent deadlocks
  PERFORM 1
  FROM public.teams
  WHERE room_id = p_room_id
  ORDER BY id ASC
  FOR UPDATE;

  UPDATE public.rooms
  SET status = 'LOBBY',
      started_at = NULL,
      ends_at = NULL
  WHERE id = p_room_id;

  FOR v_biz IN
    SELECT tb.team_id, tb.business_key, tb.level
    FROM public.team_businesses tb
    JOIN public.teams t ON tb.team_id = t.id
    WHERE t.room_id = p_room_id
  LOOP
    INSERT INTO public.activity_events (
      room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      p_room_id, v_biz.team_id, 'BUSINESS_REMOVED', v_biz.business_key,
      jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'CORRECTION'),
      trim(note), true, auth.uid(), public.app_now()
    );
  END LOOP;

  DELETE FROM public.team_businesses
  WHERE team_id IN (
    SELECT id FROM public.teams WHERE room_id = p_room_id
  );

  UPDATE public.teams
  SET cash = 1000,
      is_bankrupt = false,
      tiebreak_order = NULL,
      version = version + 1
  WHERE room_id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, prev, new, is_correction, actor_id, created_at
  ) VALUES (
    p_room_id,
    request_id,
    'GAME_ABORTED',
    trim(note),
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('status', 'LOBBY', 'teams_reset', true),
    true,
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
  RETURN v_room;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_room(team_count integer, teams jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_code text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_team_id uuid;
  v_team_elem jsonb;
  v_name text;
  v_color text;
  v_pin text;
  i int;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Multi-admin workspace isolation: check if THIS admin already has an active room
  IF EXISTS (
    SELECT 1 FROM public.rooms
    WHERE status <> 'FINALIZED'
      AND (created_by = auth.uid() OR (created_by IS NULL AND auth.uid() IS NULL))
  ) THEN
    PERFORM public.raise_error('NON_FINAL_ROOM_EXISTS');
  END IF;

  IF team_count NOT BETWEEN 5 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('team_count', team_count));
  END IF;

  IF jsonb_array_length(teams) <> team_count THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('teams_length', jsonb_array_length(teams)));
  END IF;

  -- Generate unique 6-character room code across all non-finalized rooms
  LOOP
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, floor(random() * 32)::int + 1, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.rooms WHERE code = v_code AND status <> 'FINALIZED');
  END LOOP;

  INSERT INTO public.rooms (code, status, team_count, created_by, created_at)
  VALUES (v_code, 'CREATED', team_count, auth.uid(), public.app_now())
  RETURNING id INTO v_room_id;

  -- Insert teams & unique PINs
  FOR i IN 1..team_count LOOP
    v_team_elem := teams->(i - 1);
    v_name := trim(coalesce(v_team_elem->>'name', ''));
    v_color := upper(trim(coalesce(v_team_elem->>'color', '')));

    IF char_length(v_name) < 1 OR char_length(v_name) > 30 OR v_color !~ '^#[0-9A-Fa-f]{6}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('slot', i, 'name', v_name, 'color', v_color));
    END IF;

    -- Generate random 4-digit PIN unique within this room
    LOOP
      v_pin := lpad(floor(random() * 10000)::text, 4, '0');
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.team_secrets ts
        JOIN public.teams t ON ts.team_id = t.id
        WHERE t.room_id = v_room_id AND ts.join_pin = v_pin
      );
    END LOOP;

    INSERT INTO public.teams (room_id, slot, name, color, cash, version, created_at)
    VALUES (v_room_id, i, v_name, v_color, 1000, 0, public.app_now())
    RETURNING id INTO v_team_id;

    INSERT INTO public.team_secrets (team_id, join_pin)
    VALUES (v_team_id, v_pin);
  END LOOP;

  INSERT INTO public.activity_events (
    room_id,
    type,
    note,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    'ROOM_CREATED',
    'Room created with ' || team_count::text || ' teams by admin workspace ' || coalesce(auth.uid()::text, 'system'),
    auth.uid(),
    public.app_now()
  );

  SELECT jsonb_build_object(
    'id', r.id,
    'code', r.code,
    'status', r.status,
    'team_count', r.team_count,
    'created_at', r.created_at,
    'teams', coalesce(jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'slot', t.slot,
        'name', t.name,
        'color', t.color,
        'pin', ts.join_pin
      ) ORDER BY t.slot
    ), '[]'::jsonb)
  ) INTO v_room
  FROM public.rooms r
  JOIN public.teams t ON r.id = t.room_id
  JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE r.id = v_room_id
  GROUP BY r.id, r.code, r.status, r.team_count, r.created_at;

  RETURN v_room;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_start_game(room_id uuid, force boolean DEFAULT false, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_duration int;
  v_team_count int;
  v_started_prev timestamptz;
  v_ends_prev timestamptz;
  v_unclaimed_slots jsonb;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status, duration_seconds, team_count, started_at, ends_at
  INTO v_status, v_duration, v_team_count, v_started_prev, v_ends_prev
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(room_id, request_id, 'GAME_STARTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
    RETURN v_room;
  END IF;

  IF v_status <> 'LOBBY' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'ACTIVE'));
  END IF;

  -- Defense in depth: a LOBBY room must be pristine.
  IF v_started_prev IS NOT NULL OR v_ends_prev IS NOT NULL
     OR (SELECT count(*) FROM public.teams t WHERE t.room_id = admin_start_game.room_id) <> v_team_count
     OR EXISTS (
       SELECT 1 FROM public.teams t
       WHERE t.room_id = admin_start_game.room_id
         AND (t.cash <> 1000 OR t.is_bankrupt
              OR EXISTS (SELECT 1 FROM public.team_businesses tb WHERE tb.team_id = t.id))
     ) THEN
    PERFORM public.raise_error('INVALID_INITIAL_STATE', jsonb_build_object('room_id', room_id));
  END IF;

  IF NOT force THEN
    SELECT jsonb_agg(t.slot ORDER BY t.slot) INTO v_unclaimed_slots
    FROM public.teams t
    WHERE t.room_id = admin_start_game.room_id
      AND NOT EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id);

    IF v_unclaimed_slots IS NOT NULL AND jsonb_array_length(v_unclaimed_slots) > 0 THEN
      PERFORM public.raise_error('TEAMS_NOT_JOINED', jsonb_build_object('unclaimed_slots', v_unclaimed_slots));
    END IF;
  END IF;

  v_started_at := public.app_now();
  v_ends_at := v_started_at + (v_duration || ' seconds')::interval;

  UPDATE public.rooms
  SET status = 'ACTIVE',
      started_at = v_started_at,
      ends_at = v_ends_at
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    room_id,
    request_id,
    'GAME_STARTED',
    format('Gameplay started. %s:%s countdown active.', lpad((v_duration / 60)::text, 2, '0'), lpad((v_duration % 60)::text, 2, '0')),
    auth.uid(),
    v_started_at
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_admin_snapshot(room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room jsonb;
  v_teams jsonb;
  v_events jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(room_id);

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'slot', t.slot, 'name', t.name, 'color', t.color,
    'cash', t.cash, 'board_position', t.board_position,
    'is_bankrupt', t.is_bankrupt, 'version', t.version, 'tiebreak_order', t.tiebreak_order,
    'claimed', EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id),
    'pin', ts.join_pin,
    'businesses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'business_key', tb.business_key, 'name', bc.name, 'level', tb.level,
        'cost', bc.cost
      ) ORDER BY bc.sort_order)
      FROM public.team_businesses tb JOIN public.business_catalog bc ON tb.business_key = bc.key
      WHERE tb.team_id = t.id
    ), '[]'::jsonb)
  ) ORDER BY t.slot), '[]'::jsonb) INTO v_teams
  FROM public.teams t LEFT JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE t.room_id = get_admin_snapshot.room_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', ae.id, 'team_id', ae.team_id, 'group_id', ae.group_id, 'type', ae.type,
    'business_key', ae.business_key, 'prev', ae.prev, 'new', ae.new, 'note', ae.note,
    'is_correction', ae.is_correction, 'created_at', ae.created_at
  ) ORDER BY ae.id DESC), '[]'::jsonb) INTO v_events
  FROM (SELECT * FROM public.activity_events WHERE public.activity_events.room_id = get_admin_snapshot.room_id ORDER BY id DESC LIMIT 200) ae;

  RETURN jsonb_build_object('room', v_room, 'server_now', public.app_now(), 'teams', v_teams, 'events', v_events);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_team_snapshot(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_team jsonb;
  v_businesses jsonb;
BEGIN
  SELECT to_jsonb(t.*) INTO v_team
  FROM public.teams t
  WHERE t.id = p_team_id;

  IF v_team IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = p_team_id;

  RETURN jsonb_build_object('team', v_team, 'businesses', v_businesses);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_history_detail(room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room jsonb;
  v_results jsonb;
  v_events jsonb;
  v_businesses jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT to_jsonb(r.*) INTO v_room
  FROM public.rooms r
  WHERE r.id = room_id AND r.status = 'FINALIZED';

  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', room_id));
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'team_id', fr.team_id,
      'rank', fr.rank,
      'name', t.name,
      'color', t.color,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) ORDER BY fr.rank ASC
  ), '[]'::jsonb) INTO v_results
  FROM public.final_results fr
  JOIN public.teams t ON fr.team_id = t.id
  WHERE fr.room_id = get_history_detail.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ae.id,
      'team_id', ae.team_id,
      'group_id', ae.group_id,
      'type', ae.type,
      'business_key', ae.business_key,
      'prev', ae.prev,
      'new', ae.new,
      'note', ae.note,
      'is_correction', ae.is_correction,
      'created_at', ae.created_at
    ) ORDER BY ae.id DESC
  ), '[]'::jsonb) INTO v_events
  FROM public.activity_events ae
  WHERE ae.room_id = get_history_detail.room_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'team_id', b.team_id,
      'business_key', b.business_key,
      'name', b.name,
      'level', b.level,
      'cost', b.cost,
      'u1_cost', b.u1_cost,
      'u2_cost', b.u2_cost
    ) ORDER BY b.team_id, b.business_key
  ), '[]'::jsonb) INTO v_businesses
  FROM public.final_result_businesses b
  WHERE b.room_id = get_history_detail.room_id;

  RETURN jsonb_build_object(
    'room', v_room,
    'results', v_results,
    'events', v_events,
    'businesses', v_businesses,
    'snapshot_available', (v_room->>'businesses_snapshotted')::boolean
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_room_id uuid;
  v_status public.room_status;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_slot smallint;
  v_name text;
  v_color text;
  v_cash int;
  v_is_bankrupt boolean;
  v_businesses jsonb;
  v_final_result jsonb := NULL;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Priority 1: User's claim in a non-FINALIZED room
  SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
  FROM public.team_claims tc
  JOIN public.teams t ON tc.team_id = t.id
  JOIN public.rooms r ON t.room_id = r.id
  WHERE tc.user_id = v_user_id AND r.status <> 'FINALIZED'
  ORDER BY tc.claimed_at DESC
  LIMIT 1;

  -- Priority 2: User's claim in the most recently finalized room
  IF v_room_id IS NULL THEN
    SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
    FROM public.team_claims tc
    JOIN public.teams t ON tc.team_id = t.id
    JOIN public.rooms r ON t.room_id = r.id
    WHERE tc.user_id = v_user_id AND r.status = 'FINALIZED'
    ORDER BY r.finalized_at DESC NULLS LAST, tc.claimed_at DESC
    LIMIT 1;
  END IF;

  IF v_room_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_status := public.expire_if_due(v_room_id);

  SELECT status, started_at, ends_at INTO v_status, v_started_at, v_ends_at
  FROM public.rooms
  WHERE id = v_room_id;

  SELECT slot, name, color, cash, is_bankrupt
  INTO v_slot, v_name, v_color, v_cash, v_is_bankrupt
  FROM public.teams
  WHERE id = v_team_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = v_team_id;

  IF v_status = 'FINALIZED' THEN
    SELECT jsonb_build_object(
      'rank', fr.rank,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) INTO v_final_result
    FROM public.final_results fr
    WHERE fr.room_id = v_room_id AND fr.team_id = v_team_id;
  END IF;

  RETURN jsonb_build_object(
    'room', jsonb_build_object(
      'status', v_status,
      'started_at', v_started_at,
      'ends_at', v_ends_at,
      'server_now', public.app_now()
    ),
    'team', jsonb_build_object(
      'slot', v_slot,
      'name', v_name,
      'color', v_color,
      'cash', v_cash,
      'is_bankrupt', v_is_bankrupt
    ),
    'businesses', v_businesses,
    'final_result', v_final_result
  );
END;
$function$;

-- Stored CV values are removed (no compensation); constraints on the dropped columns go with them.
ALTER TABLE public.teams DROP COLUMN cv;
ALTER TABLE public.business_catalog DROP COLUMN initial_cv, DROP COLUMN u1_cv, DROP COLUMN u2_cv;
ALTER TABLE public.final_results DROP COLUMN cv;
ALTER TABLE public.final_result_businesses DROP COLUMN initial_cv, DROP COLUMN u1_cv, DROP COLUMN u2_cv;


-- Server-authoritative gameplay rules (owner decisions D6 and D7).
--  * Crossing or landing on START credits 200 inside admin_move_team, once per move, idempotent by request_id.
--  * A purchase is only accepted while the team's token stands on that business's board space.
--    Free additions and manual level changes need a note and are recorded as corrections.
--  * Rent is computed by the server (admin_charge_rent) from the business's cost and level; the client sends no amount.
-- Not covered (no rule or state exists to enforce it): persistent Debt Recovery, see the phase report.

ALTER TABLE public.business_catalog ADD COLUMN board_position smallint;
UPDATE public.business_catalog AS c
SET board_position = v.pos
FROM (VALUES
  ('ai_deeptech', 1), ('saas', 3), ('fintech', 5), ('healthtech', 7), ('edtech', 10),
  ('devtools', 13), ('cybersecurity', 15), ('cleantech', 17), ('robotics', 19), ('ecommerce', 23)
) AS v(key, pos)
WHERE c.key = v.key;
ALTER TABLE public.business_catalog
  ALTER COLUMN board_position SET NOT NULL,
  ADD CONSTRAINT business_catalog_board_position_check CHECK (board_position BETWEEN 0 AND 23),
  ADD CONSTRAINT business_catalog_board_position_key UNIQUE (board_position);

CREATE OR REPLACE FUNCTION public.admin_move_team(
  team_id uuid,
  steps smallint,
  expected_version int,
  request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_position smallint;
  v_version int;
  v_cash int;
  v_bankrupt boolean;
  v_next_position smallint;
  v_crossings int;
  v_reward int;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF steps IS NULL OR steps NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'steps'));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;
  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT board_position, version, cash, is_bankrupt INTO v_position, v_version, v_cash, v_bankrupt
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['TEAM_MOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_version,
      'board_position', v_position
    ));
  END IF;

  v_next_position := ((v_position + steps) % 24)::smallint;
  -- Reaching or passing START counts; landing exactly on it (position + steps = 24) is one crossing.
  v_crossings := (v_position + steps) / 24;
  v_reward := 200 * v_crossings;

  IF v_cash::bigint + v_reward > public.max_money() THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
  END IF;

  UPDATE public.teams
  SET board_position = v_next_position,
      cash = cash + v_reward,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id, team_id, request_id, type, prev, new, note, actor_id, created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'TEAM_MOVED',
    jsonb_build_object('board_position', v_position, 'cash', v_cash),
    jsonb_build_object('board_position', v_next_position, 'cash', v_cash + v_reward, 'steps', steps,
                       'passed_start', v_crossings > 0, 'start_reward', v_reward),
    format('Moved %s space%s to board space #%s%s.', steps, CASE WHEN steps = 1 THEN '' ELSE 's' END, v_next_position,
           CASE WHEN v_crossings > 0 THEN format(' and reached START (+%s cash)', v_reward) ELSE '' END),
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_add_business(team_id uuid, business_key text, apply_purchase boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_cost int;
  v_position smallint;
  v_space smallint;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash
  INTO v_is_bankrupt, v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_ADDED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 2 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, board_position INTO v_cost, v_space
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'business_key', business_key);

  IF apply_purchase THEN
    -- A purchase is only offered to the team whose token stands on the business's space.
    SELECT t.board_position INTO v_position FROM public.teams t WHERE t.id = team_id;
    IF v_position IS DISTINCT FROM v_space THEN
      PERFORM public.raise_error('NOT_ON_BUSINESS_SPACE', jsonb_build_object('business_key', business_key, 'board_position', v_position, 'required_position', v_space));
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
  ELSE
    -- Manual entry bypasses the purchase rules: it must be explained and is audited as a correction.
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_business_entry_requires_note'));
    END IF;
    v_is_correction := true;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_business_level(team_id uuid, business_key text, new_level smallint, apply_upgrade boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash
  INTO v_curr_ver, v_cash
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_LEVEL_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash);

  IF apply_upgrade THEN
    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
    v_is_correction := true;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE FUNCTION public.admin_charge_rent(
  payer_team_id uuid,
  business_key text,
  payer_expected_version int,
  owner_expected_version int,
  request_id uuid DEFAULT NULL,
  note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_id uuid;
  v_position smallint;
  v_owner_id uuid;
  v_level smallint;
  v_cost int;
  v_space smallint;
  v_rent int;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id, t.board_position INTO v_room_id, v_position FROM public.teams t WHERE t.id = payer_team_id;
  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  -- A retried request returns the stored result without re-validating against newer state.
  IF public.money_replay_check(v_room_id, NULL, request_id, ARRAY['ADJUSTMENT']) THEN
    RETURN (
      SELECT coalesce(jsonb_agg(public.get_team_snapshot(ae.team_id) ORDER BY ae.team_id), '[]'::jsonb)
      FROM public.activity_events ae
      WHERE ae.group_id = (SELECT g.group_id FROM public.activity_events g WHERE g.request_id = admin_charge_rent.request_id)
    );
  END IF;

  SELECT tb.team_id, tb.level INTO v_owner_id, v_level
  FROM public.team_businesses tb
  JOIN public.teams t ON t.id = tb.team_id
  WHERE t.room_id = v_room_id AND tb.business_key = admin_charge_rent.business_key;
  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF v_owner_id = payer_team_id THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'payer_team_id', 'reason', 'no rent on your own business'));
  END IF;

  SELECT bc.cost, bc.board_position INTO v_cost, v_space FROM public.business_catalog bc WHERE bc.key = admin_charge_rent.business_key;
  IF v_position IS DISTINCT FROM v_space THEN
    PERFORM public.raise_error('NOT_ON_BUSINESS_SPACE', jsonb_build_object('business_key', business_key, 'board_position', v_position, 'required_position', v_space));
  END IF;

  -- Rent is 50% / 75% / 100% of the purchase cost by upgrade level (200->100/150/200 ... 500->250/375/500).
  v_rent := v_cost * (CASE v_level WHEN 0 THEN 50 WHEN 1 THEN 75 ELSE 100 END) / 100;

  -- admin_adjust locks room then teams in id order, checks both versions (a move, sale or upgrade between the reads
  -- above and its locks bumps a version), debits the payer (INSUFFICIENT_CASH on a shortfall) and audits both sides.
  RETURN public.admin_adjust(
    jsonb_build_array(
      jsonb_build_object('team_id', payer_team_id, 'cash_delta', -v_rent, 'expected_version', payer_expected_version),
      jsonb_build_object('team_id', v_owner_id, 'cash_delta', v_rent, 'expected_version', owner_expected_version)
    ),
    'RENT', note, request_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_charge_rent(uuid, text, int, int, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_charge_rent(uuid, text, int, int, uuid, text) TO authenticated;


-- Debt Recovery and half-price forced sales (owner decisions D5 and the player handbook).
--  * teams.debt holds what a team still owes after it has nothing left to sell.
--  * A mandatory payment the team cannot cover is refused (INSUFFICIENT_CASH) while it owns a business: it must
--    force-sell first. With no business left, the unpaid part becomes debt.
--  * Every incoming amount (START, rent, cards, sale proceeds) clears debt first; the remainder is cash.
--  * A team in debt cannot buy or upgrade, and ranks as ineligible: it cannot win.
--  * A forced sale pays 50% of the original purchase cost; upgrades add nothing.

ALTER TABLE public.teams
  ADD COLUMN debt integer NOT NULL DEFAULT 0,
  ADD CONSTRAINT teams_debt_check CHECK (debt >= 0),
  ADD CONSTRAINT teams_debt_cap CHECK (debt <= 1000000000);

CREATE OR REPLACE FUNCTION public.admin_adjust(changes jsonb, label text, note text DEFAULT NULL::text, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_correction boolean := false;
  v_group_id uuid := gen_random_uuid();
  v_max bigint := public.max_money();
  v_el jsonb;
  v_key text;
  v_txt text;
  v_ids uuid[];
  v_found int;
  v_rooms int;
  v_item jsonb;
  v_team_id uuid;
  v_cash_delta int;
  v_exp_ver int;
  v_curr_ver int;
  v_curr_cash int;
  v_curr_debt int;
  v_curr_bankrupt boolean;
  v_res_cash int;
  v_res_debt int;
  v_first boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  -- Shape validation: nothing below may surface a raw cast error.
  IF changes IS NULL OR jsonb_typeof(changes) <> 'array' OR jsonb_array_length(changes) NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'changes', 'reason', 'expected array of 1..6 items'));
  END IF;

  FOR v_el IN SELECT value FROM jsonb_array_elements(changes) LOOP
    IF jsonb_typeof(v_el) <> 'object'
       OR coalesce(v_el->>'team_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id'));
    END IF;

    IF v_el ? 'cv_delta' THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cv_delta', 'reason', 'unsupported'));
    END IF;

    FOREACH v_key IN ARRAY ARRAY['cash_delta', 'expected_version'] LOOP
      v_txt := v_el->>v_key;
      IF v_txt IS NULL THEN
        IF v_key = 'expected_version' THEN
          PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'reason', 'required'));
        END IF;
        CONTINUE;
      END IF;
      -- Two steps: Postgres does not guarantee OR short-circuit order, so never cast before the regex passes.
      IF jsonb_typeof(v_el->v_key) <> 'number' OR v_txt !~ '^-?[0-9]{1,10}$' THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key));
      END IF;
      IF abs(v_txt::bigint) > v_max OR (v_key = 'expected_version' AND v_txt::bigint < 0) THEN
        PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', v_key, 'max', v_max));
      END IF;
    END LOOP;
  END LOOP;

  SELECT array_agg((value->>'team_id')::uuid ORDER BY (value->>'team_id')::uuid) INTO v_ids
  FROM jsonb_array_elements(changes);

  IF (SELECT count(DISTINCT x) FROM unnest(v_ids) x) <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'duplicate team'));
  END IF;

  SELECT count(*), count(DISTINCT t.room_id), (array_agg(t.room_id))[1]
  INTO v_found, v_rooms, v_room_id
  FROM public.teams t
  WHERE t.id = ANY (v_ids);

  IF v_found <> array_length(v_ids, 1) THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF v_rooms <> 1 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'team_id', 'reason', 'teams span several rooms'));
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Canonical order: room, then teams ascending id.
  PERFORM 1 FROM public.teams t WHERE t.id = ANY (v_ids) ORDER BY t.id FOR UPDATE;

  IF public.money_replay_check(v_room_id, NULL, request_id, ARRAY['ADJUSTMENT']) THEN
    SELECT coalesce(jsonb_agg(public.get_team_snapshot(ae.team_id) ORDER BY ae.team_id), '[]'::jsonb)
    INTO v_results
    FROM public.activity_events ae
    WHERE ae.group_id = (SELECT g.group_id FROM public.activity_events g WHERE g.request_id = admin_adjust.request_id);
    RETURN v_results;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  -- Phase 1 validation (all-or-nothing)
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);
    v_exp_ver := (v_item->>'expected_version')::int;

    SELECT version, cash, is_bankrupt INTO v_curr_ver, v_curr_cash, v_curr_bankrupt
    FROM public.teams
    WHERE id = v_team_id;

    IF v_curr_bankrupt THEN
      PERFORM public.raise_error('TEAM_BANKRUPT', jsonb_build_object('team_id', v_team_id));
    END IF;

    IF v_curr_ver <> v_exp_ver THEN
      PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
        'team_id', v_team_id,
        'expected_version', v_exp_ver,
        'current_version', v_curr_ver
      ));
    END IF;

    -- A team that still owns a business must force-sell before an unaffordable payment; with none left it goes into debt.
    IF v_curr_cash::bigint + v_cash_delta < 0
       AND EXISTS (SELECT 1 FROM public.team_businesses tb WHERE tb.team_id = v_team_id) THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object(
        'team_id', v_team_id,
        'cash', v_curr_cash,
        'delta', v_cash_delta,
        'shortfall', abs(v_curr_cash::bigint + v_cash_delta)
      ));
    END IF;

    IF v_curr_cash::bigint + v_cash_delta > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'team_id', v_team_id, 'max', v_max));
    END IF;
  END LOOP;

  -- Phase 2 execution
  FOR v_item IN SELECT * FROM jsonb_array_elements(changes) ORDER BY (value->>'team_id')::uuid ASC LOOP
    v_team_id := (v_item->>'team_id')::uuid;
    v_cash_delta := coalesce((v_item->>'cash_delta')::int, 0);

    SELECT cash, debt INTO v_curr_cash, v_curr_debt FROM public.teams WHERE id = v_team_id;

    IF v_cash_delta >= 0 THEN
      -- Incoming money clears debt first; the remainder is cash.
      v_res_debt := v_curr_debt - least(v_curr_debt, v_cash_delta);
      v_res_cash := v_curr_cash + v_cash_delta - (v_curr_debt - v_res_debt);
    ELSIF v_curr_cash + v_cash_delta >= 0 THEN
      v_res_cash := v_curr_cash + v_cash_delta;
      v_res_debt := v_curr_debt;
    ELSE
      -- Unpayable mandatory payment and nothing left to sell: the unpaid part becomes debt.
      v_res_cash := 0;
      v_res_debt := v_curr_debt - (v_curr_cash + v_cash_delta);
    END IF;

    IF v_res_debt > v_max THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'debt', 'team_id', v_team_id, 'max', v_max));
    END IF;

    UPDATE public.teams
    SET cash = v_res_cash,
        debt = v_res_debt,
        version = version + 1
    WHERE id = v_team_id;

    INSERT INTO public.activity_events (
      room_id,
      team_id,
      group_id,
      request_id,
      type,
      prev,
      new,
      note,
      is_correction,
      actor_id,
      created_at
    ) VALUES (
      v_room_id,
      v_team_id,
      v_group_id,
      CASE WHEN v_first THEN request_id ELSE NULL END,
      'ADJUSTMENT',
      jsonb_build_object('cash', v_curr_cash, 'debt', v_curr_debt),
      jsonb_build_object('cash', v_res_cash, 'debt', v_res_debt, 'cash_delta', v_cash_delta),
      coalesce(label || ': ', '') || coalesce(note, ''),
      v_is_correction,
      auth.uid(),
      public.app_now()
    );

    v_first := false;
    v_results := v_results || public.get_team_snapshot(v_team_id);
  END LOOP;

  RETURN v_results;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_move_team(team_id uuid, steps smallint, expected_version integer, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_position smallint;
  v_version int;
  v_cash int;
  v_debt int;
  v_pay int;
  v_bankrupt boolean;
  v_next_position smallint;
  v_crossings int;
  v_reward int;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF steps IS NULL OR steps NOT BETWEEN 1 AND 6 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'steps'));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;
  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  SELECT board_position, version, cash, debt, is_bankrupt INTO v_position, v_version, v_cash, v_debt, v_bankrupt
  FROM public.teams
  WHERE id = team_id AND room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['TEAM_MOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_version <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object(
      'expected_version', expected_version,
      'current_version', v_version,
      'board_position', v_position
    ));
  END IF;

  v_next_position := ((v_position + steps) % 24)::smallint;
  -- Reaching or passing START counts; landing exactly on it (position + steps = 24) is one crossing.
  v_crossings := (v_position + steps) / 24;
  v_reward := 200 * v_crossings;

  IF v_cash::bigint + v_reward > public.max_money() THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
  END IF;

  -- The reward clears outstanding debt first; the remainder is cash.
  v_pay := least(v_debt, v_reward);

  UPDATE public.teams
  SET board_position = v_next_position,
      cash = cash + v_reward - v_pay,
      debt = debt - v_pay,
      version = version + 1
  WHERE id = team_id;

  INSERT INTO public.activity_events (
    room_id, team_id, request_id, type, prev, new, note, actor_id, created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'TEAM_MOVED',
    jsonb_build_object('board_position', v_position, 'cash', v_cash, 'debt', v_debt),
    jsonb_build_object('board_position', v_next_position, 'cash', v_cash + v_reward - v_pay, 'debt', v_debt - v_pay, 'steps', steps,
                       'passed_start', v_crossings > 0, 'start_reward', v_reward),
    format('Moved %s space%s to board space #%s%s.', steps, CASE WHEN steps = 1 THEN '' ELSE 's' END, v_next_position,
           CASE WHEN v_crossings > 0 THEN format(' and reached START (+%s cash)', v_reward) ELSE '' END),
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_remove_business(team_id uuid, business_key text, reason text, credit_resale boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_debt int;
  v_pay int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF reason NOT IN ('FORCED_SALE', 'BANKRUPTCY', 'CORRECTION') THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('reason', reason));
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash, t.debt
  INTO v_curr_ver, v_cash, v_debt
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_REMOVED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF reason = 'CORRECTION' THEN
    v_is_correction := true;
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash, 'debt', v_debt);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    -- A forced sale pays 50% of the original purchase cost; upgrades add nothing and are not refunded.
    SELECT cost / 2 INTO v_cost FROM public.business_catalog WHERE key = business_key;
    IF v_cash::bigint + v_cost > public.max_money() THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('field', 'cash', 'max', public.max_money()));
    END IF;
    -- Sale proceeds clear debt first.
    v_pay := least(v_debt, v_cost);
    v_debt := v_debt - v_pay;
    v_cash := v_cash + v_cost - v_pay;
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      debt = v_debt,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object(
    'business_key', business_key,
    'reason', reason,
    'credit_resale', credit_resale,
    'cash', v_cash,
    'debt', v_debt
  );

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_REMOVED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_business(team_id uuid, business_key text, apply_purchase boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_is_bankrupt boolean;
  v_curr_ver int;
  v_cash int;
  v_debt int;
  v_cost int;
  v_position smallint;
  v_space smallint;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.is_bankrupt, t.version, t.cash, t.debt
  INTO v_is_bankrupt, v_curr_ver, v_cash, v_debt
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_ADDED']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_is_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  IF EXISTS (SELECT 1 FROM public.team_businesses WHERE room_id = v_room_id AND team_businesses.business_key = admin_add_business.business_key) THEN
    PERFORM public.raise_error('BUSINESS_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF (SELECT count(*) FROM public.team_businesses WHERE team_businesses.team_id = admin_add_business.team_id) >= 2 THEN
    PERFORM public.raise_error('BUSINESS_CAP');
  END IF;

  SELECT cost, board_position INTO v_cost, v_space
  FROM public.business_catalog
  WHERE key = business_key;

  IF NOT FOUND THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('business_key', business_key));
  END IF;

  v_prev := jsonb_build_object('cash', v_cash, 'business_key', business_key);

  IF apply_purchase THEN
    -- Debt Recovery: a team in debt cannot buy.
    IF v_debt > 0 THEN
      PERFORM public.raise_error('IN_DEBT', jsonb_build_object('debt', v_debt));
    END IF;

    -- A purchase is only offered to the team whose token stands on the business's space.
    SELECT t.board_position INTO v_position FROM public.teams t WHERE t.id = team_id;
    IF v_position IS DISTINCT FROM v_space THEN
      PERFORM public.raise_error('NOT_ON_BUSINESS_SPACE', jsonb_build_object('business_key', business_key, 'board_position', v_position, 'required_position', v_space));
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;
    v_cash := v_cash - v_cost;
  ELSE
    -- Manual entry bypasses the purchase rules: it must be explained and is audited as a correction.
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_business_entry_requires_note'));
    END IF;
    v_is_correction := true;
  END IF;

  INSERT INTO public.team_businesses (room_id, team_id, business_key, level, acquired_at)
  VALUES (v_room_id, team_id, business_key, 0, public.app_now());

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('cash', v_cash, 'business_key', business_key, 'level', 0, 'apply_purchase', apply_purchase);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_ADDED',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_business_level(team_id uuid, business_key text, new_level smallint, apply_upgrade boolean DEFAULT true, expected_version integer DEFAULT 0, request_id uuid DEFAULT NULL::uuid, note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room_id uuid;
  v_status public.room_status;
  v_curr_ver int;
  v_cash int;
  v_debt int;
  v_curr_level smallint;
  v_cost int;
  v_is_correction boolean := false;
  v_prev jsonb;
  v_new jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT t.room_id INTO v_room_id FROM public.teams t WHERE t.id = team_id;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  PERFORM public.expire_if_due(v_room_id);
  SELECT status INTO v_status FROM public.rooms WHERE id = v_room_id FOR UPDATE;

  -- Team row is locked after the room; columns are re-read under the lock.
  SELECT t.version, t.cash, t.debt
  INTO v_curr_ver, v_cash, v_debt
  FROM public.teams t
  WHERE t.id = team_id AND t.room_id = v_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.money_replay_check(v_room_id, team_id, request_id, ARRAY['BUSINESS_LEVEL_SET']) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED');
    END IF;
    v_is_correction := true;
  ELSIF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('ROOM_NOT_EDITABLE', jsonb_build_object('status', v_status));
  END IF;

  IF v_curr_ver <> expected_version THEN
    PERFORM public.raise_error('VERSION_CONFLICT', jsonb_build_object('expected_version', expected_version, 'current_version', v_curr_ver));
  END IF;

  SELECT level INTO v_curr_level
  FROM public.team_businesses
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('BUSINESS_NOT_OWNED', jsonb_build_object('business_key', business_key));
  END IF;

  IF new_level NOT BETWEEN 0 AND 2 THEN
    PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('new_level', new_level));
  END IF;

  v_prev := jsonb_build_object('level', v_curr_level, 'cash', v_cash);

  IF apply_upgrade THEN
    -- Debt Recovery: a team in debt cannot upgrade.
    IF v_debt > 0 THEN
      PERFORM public.raise_error('IN_DEBT', jsonb_build_object('debt', v_debt));
    END IF;

    IF new_level <> v_curr_level + 1 THEN
      PERFORM public.raise_error('INVALID_VALUE', jsonb_build_object('current_level', v_curr_level, 'new_level', new_level));
    END IF;

    IF new_level = 1 THEN
      SELECT u1_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    ELSIF new_level = 2 THEN
      SELECT u2_cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    END IF;

    IF v_cash < v_cost THEN
      PERFORM public.raise_error('INSUFFICIENT_CASH', jsonb_build_object('cash', v_cash, 'cost', v_cost, 'shortfall', v_cost - v_cash));
    END IF;

    v_cash := v_cash - v_cost;
  ELSE
    IF note IS NULL OR trim(note) = '' THEN
      PERFORM public.raise_error('NOTE_REQUIRED', jsonb_build_object('reason', 'manual_level_change_requires_note'));
    END IF;
    v_is_correction := true;
  END IF;

  UPDATE public.team_businesses
  SET level = new_level
  WHERE team_businesses.team_id = admin_set_business_level.team_id
    AND team_businesses.business_key = admin_set_business_level.business_key;

  UPDATE public.teams
  SET cash = v_cash,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object('level', new_level, 'cash', v_cash, 'apply_upgrade', apply_upgrade);

  INSERT INTO public.activity_events (
    room_id,
    team_id,
    request_id,
    type,
    business_key,
    prev,
    new,
    note,
    is_correction,
    actor_id,
    created_at
  ) VALUES (
    v_room_id,
    team_id,
    request_id,
    'BUSINESS_LEVEL_SET',
    business_key,
    v_prev,
    v_new,
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$function$;

DROP FUNCTION IF EXISTS public.room_standings(uuid);

CREATE FUNCTION public.room_standings(p_room_id uuid)
RETURNS TABLE(team_id uuid, slot smallint, name text, rank integer, is_bankrupt boolean, debt integer, cash integer,
              business_count integer, business_cost integer, upgrade_count integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT t.id AS tid, t.slot, t.name, t.is_bankrupt, t.debt, t.cash,
           count(tb.id)::int AS business_count,
           coalesce(sum(bc.cost), 0)::int AS business_cost,
           coalesce(sum(tb.level), 0)::int AS upgrade_count
    FROM public.teams t
    LEFT JOIN public.team_businesses tb ON tb.team_id = t.id
    LEFT JOIN public.business_catalog bc ON bc.key = tb.business_key
    WHERE t.room_id = p_room_id
    GROUP BY t.id
  )
  SELECT b.tid, b.slot, b.name,
         -- A team still in debt (or eliminated) is ineligible: it ranks below every eligible team and cannot win.
         (rank() OVER (ORDER BY (b.is_bankrupt OR b.debt > 0) ASC, b.cash DESC, b.business_cost DESC, b.upgrade_count DESC))::int,
         b.is_bankrupt, b.debt, b.cash, b.business_count, b.business_cost, b.upgrade_count
  FROM base b
  ORDER BY 4 ASC, b.slot ASC;
$function$;

REVOKE ALL ON FUNCTION public.room_standings(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_finalize(p_room_id uuid, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_FINALIZED') THEN
    SELECT winner_team_id INTO v_winner_id FROM public.rooms WHERE id = p_room_id;
    SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
    INTO v_standings
    FROM public.room_standings(p_room_id) s;
    RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
  END IF;

  IF v_status <> 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Canonical order: room (held), then teams ascending id. No correction can interleave from here on.
  PERFORM 1 FROM public.teams WHERE room_id = p_room_id ORDER BY id ASC FOR UPDATE;

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  INSERT INTO public.final_results (room_id, team_id, rank, cash, business_count, is_bankrupt)
  SELECT p_room_id, (e->>'team_id')::uuid, (e->>'rank')::smallint, (e->>'cash')::int,
         (e->>'business_count')::smallint, (e->>'is_bankrupt')::boolean OR (e->>'debt')::int > 0
  FROM jsonb_array_elements(v_standings) e;

  INSERT INTO public.final_result_businesses (
    room_id, team_id, business_key, name, level, cost, u1_cost, u2_cost
  )
  SELECT p_room_id, tb.team_id, tb.business_key, bc.name, tb.level, bc.cost,
         bc.u1_cost, bc.u2_cost
  FROM public.team_businesses tb
  JOIN public.teams t ON t.id = tb.team_id
  JOIN public.business_catalog bc ON bc.key = tb.business_key
  WHERE t.room_id = p_room_id;

  -- Teams that tie on every criterion share rank 1: then there is no single winner.
  SELECT CASE WHEN count(*) = 1 THEN min(e->>'team_id')::uuid END INTO v_winner_id
  FROM jsonb_array_elements(v_standings) e
  WHERE (e->>'rank')::int = 1 AND NOT (e->>'is_bankrupt')::boolean AND (e->>'debt')::int = 0;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      businesses_snapshotted = true,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    p_room_id, request_id, 'GAME_FINALIZED', 'Match finalized. Leaderboard permanently snapshotted.', auth.uid(), public.app_now()
  );

  RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_admin_snapshot(room_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_room jsonb;
  v_teams jsonb;
  v_events jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(room_id);

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  IF v_room IS NULL THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'slot', t.slot, 'name', t.name, 'color', t.color,
    'cash', t.cash, 'debt', t.debt, 'board_position', t.board_position,
    'is_bankrupt', t.is_bankrupt, 'version', t.version, 'tiebreak_order', t.tiebreak_order,
    'claimed', EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id),
    'pin', ts.join_pin,
    'businesses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'business_key', tb.business_key, 'name', bc.name, 'level', tb.level,
        'cost', bc.cost
      ) ORDER BY bc.sort_order)
      FROM public.team_businesses tb JOIN public.business_catalog bc ON tb.business_key = bc.key
      WHERE tb.team_id = t.id
    ), '[]'::jsonb)
  ) ORDER BY t.slot), '[]'::jsonb) INTO v_teams
  FROM public.teams t LEFT JOIN public.team_secrets ts ON t.id = ts.team_id
  WHERE t.room_id = get_admin_snapshot.room_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', ae.id, 'team_id', ae.team_id, 'group_id', ae.group_id, 'type', ae.type,
    'business_key', ae.business_key, 'prev', ae.prev, 'new', ae.new, 'note', ae.note,
    'is_correction', ae.is_correction, 'created_at', ae.created_at
  ) ORDER BY ae.id DESC), '[]'::jsonb) INTO v_events
  FROM (SELECT * FROM public.activity_events WHERE public.activity_events.room_id = get_admin_snapshot.room_id ORDER BY id DESC LIMIT 200) ae;

  RETURN jsonb_build_object('room', v_room, 'server_now', public.app_now(), 'teams', v_teams, 'events', v_events);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_room_id uuid;
  v_status public.room_status;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_slot smallint;
  v_name text;
  v_color text;
  v_cash int;
  v_debt int;
  v_is_bankrupt boolean;
  v_businesses jsonb;
  v_final_result jsonb := NULL;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Priority 1: User's claim in a non-FINALIZED room
  SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
  FROM public.team_claims tc
  JOIN public.teams t ON tc.team_id = t.id
  JOIN public.rooms r ON t.room_id = r.id
  WHERE tc.user_id = v_user_id AND r.status <> 'FINALIZED'
  ORDER BY tc.claimed_at DESC
  LIMIT 1;

  -- Priority 2: User's claim in the most recently finalized room
  IF v_room_id IS NULL THEN
    SELECT tc.team_id, t.room_id INTO v_team_id, v_room_id
    FROM public.team_claims tc
    JOIN public.teams t ON tc.team_id = t.id
    JOIN public.rooms r ON t.room_id = r.id
    WHERE tc.user_id = v_user_id AND r.status = 'FINALIZED'
    ORDER BY r.finalized_at DESC NULLS LAST, tc.claimed_at DESC
    LIMIT 1;
  END IF;

  IF v_room_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_status := public.expire_if_due(v_room_id);

  SELECT status, started_at, ends_at INTO v_status, v_started_at, v_ends_at
  FROM public.rooms
  WHERE id = v_room_id;

  SELECT slot, name, color, cash, debt, is_bankrupt
  INTO v_slot, v_name, v_color, v_cash, v_debt, v_is_bankrupt
  FROM public.teams
  WHERE id = v_team_id;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'business_key', tb.business_key,
      'name', bc.name,
      'level', tb.level,
      'cost', bc.cost
    ) ORDER BY bc.sort_order
  ), '[]'::jsonb) INTO v_businesses
  FROM public.team_businesses tb
  JOIN public.business_catalog bc ON tb.business_key = bc.key
  WHERE tb.team_id = v_team_id;

  IF v_status = 'FINALIZED' THEN
    SELECT jsonb_build_object(
      'rank', fr.rank,
      'cash', fr.cash,
      'business_count', fr.business_count,
      'is_bankrupt', fr.is_bankrupt
    ) INTO v_final_result
    FROM public.final_results fr
    WHERE fr.room_id = v_room_id AND fr.team_id = v_team_id;
  END IF;

  RETURN jsonb_build_object(
    'room', jsonb_build_object(
      'status', v_status,
      'started_at', v_started_at,
      'ends_at', v_ends_at,
      'server_now', public.app_now()
    ),
    'team', jsonb_build_object(
      'slot', v_slot,
      'name', v_name,
      'color', v_color,
      'cash', v_cash,
      'debt', v_debt,
      'is_bankrupt', v_is_bankrupt
    ),
    'businesses', v_businesses,
    'final_result', v_final_result
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_abort_game(p_room_id uuid, note text DEFAULT NULL::text, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_room jsonb;
  v_biz RECORD;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF note IS NULL OR trim(note) = '' THEN
    PERFORM public.raise_error('NOTE_REQUIRED');
  END IF;

  -- Flip a passed deadline to TIME_EXPIRED first (takes the room lock).
  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_ABORTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
    RETURN v_room;
  END IF;

  IF v_status = 'TIME_EXPIRED' THEN
    PERFORM public.raise_error('ROOM_ALREADY_EXPIRED', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF v_status <> 'ACTIVE' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'LOBBY'));
  END IF;

  -- Lock teams in deterministic ID order to prevent deadlocks
  PERFORM 1
  FROM public.teams
  WHERE room_id = p_room_id
  ORDER BY id ASC
  FOR UPDATE;

  UPDATE public.rooms
  SET status = 'LOBBY',
      started_at = NULL,
      ends_at = NULL
  WHERE id = p_room_id;

  FOR v_biz IN
    SELECT tb.team_id, tb.business_key, tb.level
    FROM public.team_businesses tb
    JOIN public.teams t ON tb.team_id = t.id
    WHERE t.room_id = p_room_id
  LOOP
    INSERT INTO public.activity_events (
      room_id, team_id, type, business_key, prev, new, note, is_correction, actor_id, created_at
    ) VALUES (
      p_room_id, v_biz.team_id, 'BUSINESS_REMOVED', v_biz.business_key,
      jsonb_build_object('level', v_biz.level), jsonb_build_object('reason', 'CORRECTION'),
      trim(note), true, auth.uid(), public.app_now()
    );
  END LOOP;

  DELETE FROM public.team_businesses
  WHERE team_id IN (
    SELECT id FROM public.teams WHERE room_id = p_room_id
  );

  UPDATE public.teams
  SET cash = 1000,
      debt = 0,
      is_bankrupt = false,
      tiebreak_order = NULL,
      version = version + 1
  WHERE room_id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, prev, new, is_correction, actor_id, created_at
  ) VALUES (
    p_room_id,
    request_id,
    'GAME_ABORTED',
    trim(note),
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('status', 'LOBBY', 'teams_reset', true),
    true,
    auth.uid(),
    public.app_now()
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = p_room_id;
  RETURN v_room;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_start_game(room_id uuid, force boolean DEFAULT false, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_duration int;
  v_team_count int;
  v_started_prev timestamptz;
  v_ends_prev timestamptz;
  v_unclaimed_slots jsonb;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_room jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  SELECT status, duration_seconds, team_count, started_at, ends_at
  INTO v_status, v_duration, v_team_count, v_started_prev, v_ends_prev
  FROM public.rooms
  WHERE id = room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND');
  END IF;

  IF public.lifecycle_replay_check(room_id, request_id, 'GAME_STARTED') THEN
    SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
    RETURN v_room;
  END IF;

  IF v_status <> 'LOBBY' THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'ACTIVE'));
  END IF;

  -- Defense in depth: a LOBBY room must be pristine.
  IF v_started_prev IS NOT NULL OR v_ends_prev IS NOT NULL
     OR (SELECT count(*) FROM public.teams t WHERE t.room_id = admin_start_game.room_id) <> v_team_count
     OR EXISTS (
       SELECT 1 FROM public.teams t
       WHERE t.room_id = admin_start_game.room_id
         AND (t.cash <> 1000 OR t.debt <> 0 OR t.is_bankrupt
              OR EXISTS (SELECT 1 FROM public.team_businesses tb WHERE tb.team_id = t.id))
     ) THEN
    PERFORM public.raise_error('INVALID_INITIAL_STATE', jsonb_build_object('room_id', room_id));
  END IF;

  IF NOT force THEN
    SELECT jsonb_agg(t.slot ORDER BY t.slot) INTO v_unclaimed_slots
    FROM public.teams t
    WHERE t.room_id = admin_start_game.room_id
      AND NOT EXISTS (SELECT 1 FROM public.team_claims tc WHERE tc.team_id = t.id);

    IF v_unclaimed_slots IS NOT NULL AND jsonb_array_length(v_unclaimed_slots) > 0 THEN
      PERFORM public.raise_error('TEAMS_NOT_JOINED', jsonb_build_object('unclaimed_slots', v_unclaimed_slots));
    END IF;
  END IF;

  v_started_at := public.app_now();
  v_ends_at := v_started_at + (v_duration || ' seconds')::interval;

  UPDATE public.rooms
  SET status = 'ACTIVE',
      started_at = v_started_at,
      ends_at = v_ends_at
  WHERE id = room_id;

  INSERT INTO public.activity_events (
    room_id, request_id, type, note, actor_id, created_at
  ) VALUES (
    room_id,
    request_id,
    'GAME_STARTED',
    format('Gameplay started. %s:%s countdown active.', lpad((v_duration / 60)::text, 2, '0'), lpad((v_duration % 60)::text, 2, '0')),
    auth.uid(),
    v_started_at
  );

  SELECT to_jsonb(r.*) INTO v_room FROM public.rooms r WHERE r.id = room_id;
  RETURN v_room;
END;
$function$;


-- Multi-admin rooms: 0026 scoped the NON_FINAL_ROOM_EXISTS check per admin, but the global
-- one-non-final-room index from 0001 still blocked every other admin. Drop it.
-- idx_rooms_unique_active_code stays: room codes remain unique among non-final rooms.
-- Audit: no other function assumes a single global active room (player lookups are per user/room).
DROP INDEX IF EXISTS public.idx_rooms_single_active;


-- Migration 0033: Allow Admin to Finalize Match at Any Time (ACTIVE or TIME_EXPIRED)
-- STARTUPOLY Live Scoreboard & Game Management System

CREATE OR REPLACE FUNCTION public.admin_finalize(p_room_id uuid, request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.room_status;
  v_winner_id uuid;
  v_standings jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  PERFORM public.expire_if_due(p_room_id);

  SELECT status INTO v_status
  FROM public.rooms
  WHERE id = p_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.raise_error('ROOM_NOT_FOUND', jsonb_build_object('room_id', p_room_id));
  END IF;

  IF public.lifecycle_replay_check(p_room_id, request_id, 'GAME_FINALIZED') THEN
    SELECT winner_team_id INTO v_winner_id FROM public.rooms WHERE id = p_room_id;
    SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
    INTO v_standings
    FROM public.room_standings(p_room_id) s;
    RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
  END IF;

  -- Allow finalizing whether time has expired or early during active match
  IF v_status NOT IN ('ACTIVE', 'TIME_EXPIRED') THEN
    PERFORM public.raise_error('INVALID_TRANSITION', jsonb_build_object('from', v_status, 'to', 'FINALIZED'));
  END IF;

  -- Canonical order: room (held), then teams ascending id. No correction can interleave from here on.
  PERFORM 1 FROM public.teams WHERE room_id = p_room_id ORDER BY id ASC FOR UPDATE;

  SELECT coalesce(jsonb_agg(to_jsonb(s.*) ORDER BY s.rank ASC), '[]'::jsonb)
  INTO v_standings
  FROM public.room_standings(p_room_id) s;

  INSERT INTO public.final_results (room_id, team_id, rank, cash, business_count, is_bankrupt)
  SELECT p_room_id, (e->>'team_id')::uuid, (e->>'rank')::smallint, (e->>'cash')::int,
         (e->>'business_count')::smallint, (e->>'is_bankrupt')::boolean OR (e->>'debt')::int > 0
  FROM jsonb_array_elements(v_standings) e;

  INSERT INTO public.final_result_businesses (
    room_id, team_id, business_key, name, level, cost, u1_cost, u2_cost
  )
  SELECT p_room_id, tb.team_id, tb.business_key, bc.name, tb.level, bc.cost,
         bc.u1_cost, bc.u2_cost
  FROM public.team_businesses tb
  JOIN public.teams t ON t.id = tb.team_id
  JOIN public.business_catalog bc ON bc.key = tb.business_key
  WHERE t.room_id = p_room_id;

  -- Winner: rank = 1
  SELECT (e->>'team_id')::uuid INTO v_winner_id
  FROM jsonb_array_elements(v_standings) e
  WHERE (e->>'rank')::int = 1
  LIMIT 1;

  UPDATE public.rooms
  SET status = 'FINALIZED',
      winner_team_id = v_winner_id,
      finalized_at = public.app_now()
  WHERE id = p_room_id;

  INSERT INTO public.activity_events (
    room_id, type, note, request_id, created_at
  ) VALUES (
    p_room_id, 'GAME_FINALIZED',
    'Match finalized. Official results recorded.',
    request_id, public.app_now()
  );

  RETURN jsonb_build_object('room_id', p_room_id, 'winner_team_id', v_winner_id, 'standings', v_standings);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_finalize(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_finalize(uuid, uuid) TO authenticated;
