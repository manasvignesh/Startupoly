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
