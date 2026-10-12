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
