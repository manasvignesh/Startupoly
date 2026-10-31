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
