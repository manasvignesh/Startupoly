-- Migration 0018: Lifecycle Deadlock & Schema Reconciliation
-- 1. Lifecycle Deadlock Resolution: Allow room transition from TIME_EXPIRED back to LOBBY
--    in fn_check_room_status_transition so matches whose timer expired can be aborted/reset.
-- 2. Enhanced admin_abort_game: Allow admin_abort_game to be invoked when room status is
--    either 'ACTIVE' or 'TIME_EXPIRED'.
-- 3. Redundant Index Pruning: Drop idx_team_claims_team_id since idx_team_claims_one_active_claim_per_team
--    already enforces uniqueness and covers all lookups on team_id.
-- 4. Schema Reconciliation: Drop orphaned final_result_businesses if present from legacy iterations.

BEGIN;

-- 1. Update fn_check_room_status_transition to allow TIME_EXPIRED -> LOBBY
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
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'FINALIZED') OR
      (OLD.status = 'TIME_EXPIRED' AND NEW.status = 'LOBBY')
    ) THEN
      RAISE EXCEPTION 'INVALID_TRANSITION';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 2. Update admin_abort_game to support both ACTIVE and TIME_EXPIRED room statuses
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

  IF v_status NOT IN ('ACTIVE', 'TIME_EXPIRED') THEN
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
    jsonb_build_object('status', v_status),
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

-- 3. Prune redundant index on team_claims
DROP INDEX IF EXISTS public.idx_team_claims_team_id;

-- 4. Reconcile schema: drop orphaned table if exists
DROP TABLE IF EXISTS public.final_result_businesses CASCADE;

COMMIT;
