-- pgTAP Regression Suite: Security Hardening, Anti-Brute-Force & Search Path Hygiene

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(7);
SELECT set_config('app.env', 'test', true);
SELECT set_config('app.test_now', '2026-03-01 10:00:00+00', true);

\set admin_uid 'a7000000-0000-0000-0000-000000000001'
\set player_one 'b7000000-0000-0000-0000-000000000001'

INSERT INTO auth.users (id, email, created_at, updated_at)
VALUES
  (:'admin_uid', 'sec-admin@test.local', now(), now()),
  (:'player_one', 'sec-p1@test.local', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.admins (user_id)
VALUES (:'admin_uid')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "a7000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

-- 1. Create room and open lobby
SELECT lives_ok(
  $$SELECT public.admin_create_room(
      5,
      '[{"name":"Sec A","color":"#BA0001"},{"name":"Sec B","color":"#BA0002"},
        {"name":"Sec C","color":"#BA0003"},{"name":"Sec D","color":"#BA0004"},
        {"name":"Sec E","color":"#BA0005"}]'::jsonb
  )$$,
  'Admin creates room for security hardening test'
);

SELECT lives_ok(
  $$SELECT public.admin_open_lobby(id) FROM public.rooms WHERE status = 'CREATED'$$,
  'Admin opens lobby'
);

-- 2. Verify search_path is set to public on trigger/helper functions
SELECT is(
  (
    SELECT count(*)::int
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'fn_check_business_cap',
        'fn_check_team_room_immutable',
        'fn_check_team_business_room_immutable',
        'fn_check_room_immutable',
        'fn_check_room_status_transition',
        'fn_check_immutable_table',
        'raise_error'
      )
      AND NOT ('search_path=public' = ANY(p.proconfig))
  ),
  0,
  'All audited trigger & helper functions have search_path=public explicitly configured'
);

-- 3. Connect player one to Team 1
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "b7000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

SELECT lives_ok(
  $$SELECT public.join_team(
      r.code,
      1,
      (SELECT ts.join_pin FROM public.team_secrets ts JOIN public.teams t ON t.id = ts.team_id WHERE t.room_id = r.id AND t.slot = 1)
  )
  FROM public.rooms r
  WHERE r.status = 'LOBBY'$$,
  'Player one joins team 1'
);

-- 4. Oracle elimination: Attempting to join an already-claimed team with a WRONG PIN
-- must raise TEAM_ALREADY_CLAIMED, not BAD_CODE_OR_PIN
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "c7000000-0000-0000-0000-000000000099", "role": "authenticated"}',
  true
);

SELECT throws_ok(
  $$SELECT public.join_team(
      (SELECT code FROM public.rooms WHERE status = 'LOBBY'),
      1,
      '0000'
  )$$,
  'P0001',
  'TEAM_ALREADY_CLAIMED',
  'Exclusivity check fires before PIN check, preventing PIN oracle attacks'
);

-- 5. Anti-brute-force rate limiting: Simulate 10 failed PIN attempts from 10 distinct user_ids for Team Slot 2
DO $$
DECLARE
  v_code text;
  v_team_id uuid;
  i int;
BEGIN
  SELECT code INTO v_code FROM public.rooms WHERE status = 'LOBBY';
  SELECT id INTO v_team_id FROM public.teams WHERE slot = 2;

  -- Insert 10 failed attempts for team slot 2 from distinct user IDs
  FOR i IN 1..10 LOOP
    INSERT INTO public.join_attempts (user_id, team_id, success, attempted_at)
    VALUES (gen_random_uuid(), v_team_id, false, public.app_now());
  END LOOP;
END $$;

-- The 11th attempt from a fresh user must be blocked by team-level throttling
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "d7000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

SELECT throws_ok(
  $$SELECT public.join_team(
      (SELECT code FROM public.rooms WHERE status = 'LOBBY'),
      2,
      '1234'
  )$$,
  'P0001',
  'TOO_MANY_ATTEMPTS',
  'Team-slot throttling stops anonymous session rotation brute-force attacks'
);

SELECT * FROM finish();
ROLLBACK;
