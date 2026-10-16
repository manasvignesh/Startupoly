-- Migration 0016: Security Hardening & Rate Limiting
-- 1. Anti-Brute-Force Rate Limiting: Throttle failed join attempts per target team slot
--    in addition to per-user throttle, preventing anonymous session rotation attacks.
-- 2. Oracle Elimination: Block PIN testing on already-claimed teams before PIN validation.
-- 3. Clock Security: Restrict app_now() simulated clock to privileged test roles only.
-- 4. Search Path Hygiene: Add explicit SET search_path = public to all trigger & helper functions.

BEGIN;

-- 1. Secure app_now() to ignore test GUCs from external PostgREST clients
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
  -- Only respect test clock when app.env is explicitly 'test' AND caller is not an external PostgREST client
  IF test_now IS NOT NULL AND test_now <> '' AND app_env = 'test' THEN
    IF nullif(current_setting('request.jwt.claim.role', true), '') IS NULL OR current_user IN ('postgres', 'supabase_admin') THEN
      RETURN test_now::timestamptz;
    END IF;
  END IF;
  RETURN clock_timestamp();
END;
$$;

-- 2. Add SET search_path = public to core helper & trigger functions
CREATE OR REPLACE FUNCTION public.raise_error(
  err_code text,
  detail jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION '%', err_code USING DETAIL = detail::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_check_business_cap()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (SELECT count(*) FROM public.team_businesses WHERE team_id = NEW.team_id) >= 3 THEN
    RAISE EXCEPTION 'BUSINESS_CAP';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_check_team_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
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

CREATE OR REPLACE FUNCTION public.fn_check_team_business_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
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

CREATE OR REPLACE FUNCTION public.fn_check_room_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.status = 'FINALIZED' THEN
    RAISE EXCEPTION 'ROOM_FINALIZED';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_check_room_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
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

CREATE OR REPLACE FUNCTION public.fn_check_immutable_table()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE';
END;
$$;

-- 3. Hardened join_team stored procedure with anti-brute-force slot throttling
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
  v_user_fail_count int;
  v_team_fail_count int;
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

  -- 1. User-level throttling: Max 5 failed attempts in last 60 seconds
  SELECT count(*) INTO v_user_fail_count
  FROM public.join_attempts
  WHERE user_id = v_user_id
    AND success = false
    AND attempted_at >= public.app_now() - interval '60 seconds';

  IF v_user_fail_count >= 5 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  -- 2. Validate room
  SELECT id, status INTO v_room_id, v_status
  FROM public.rooms
  WHERE public.rooms.code = v_code
    AND status IN ('LOBBY', 'ACTIVE', 'TIME_EXPIRED');

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- 3. Validate team slot
  SELECT id, name INTO v_team_id, v_name
  FROM public.teams
  WHERE room_id = v_room_id AND teams.slot = join_team.slot;

  IF NOT FOUND THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, NULL, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- 4. Target team slot throttling (Max 10 failed attempts across all sessions in 60s)
  -- Defeats anonymous session rotation attacks against 4-digit PIN
  SELECT count(*) INTO v_team_fail_count
  FROM public.join_attempts
  WHERE team_id = v_team_id
    AND success = false
    AND attempted_at >= public.app_now() - interval '60 seconds';

  IF v_team_fail_count >= 10 THEN
    PERFORM public.raise_error('TOO_MANY_ATTEMPTS', jsonb_build_object('retry_after_seconds', 60));
  END IF;

  -- 5. Exclusivity check BEFORE PIN verification (eliminates timing/pin confirmation oracle)
  IF EXISTS (
    SELECT 1
    FROM public.team_claims
    WHERE team_id = v_team_id
      AND user_id <> v_user_id
  ) THEN
    PERFORM public.raise_error('TEAM_ALREADY_CLAIMED');
  END IF;

  -- 6. Validate PIN
  SELECT join_pin INTO v_real_pin
  FROM public.team_secrets
  WHERE team_id = v_team_id;

  IF v_real_pin IS DISTINCT FROM v_pin THEN
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (v_user_id, v_team_id, false, public.app_now());
    PERFORM public.raise_error('BAD_CODE_OR_PIN');
  END IF;

  -- 7. Success: record success and create claim
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
