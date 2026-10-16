-- pgTAP Regression Suite: Game Accounting, CV Integrity & Bankruptcy Enforcement

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(8);
SELECT set_config('app.env', 'test', true);
SELECT set_config('app.test_now', '2026-03-01 10:00:00+00', true);

\set admin_uid 'a8000000-0000-0000-0000-000000000001'

INSERT INTO auth.users (id, email, created_at, updated_at)
VALUES (:'admin_uid', 'acct-admin@test.local', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.admins (user_id)
VALUES (:'admin_uid')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "a8000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

-- 1. Setup room, open lobby and start game
SELECT lives_ok(
  $$SELECT public.admin_create_room(
      3,
      '[{"name":"Team Alpha","color":"#BA0001"},{"name":"Team Beta","color":"#BA0002"},
        {"name":"Team Gamma","color":"#BA0003"}]'::jsonb
  )$$,
  'Admin creates room for accounting test'
);

SELECT lives_ok(
  $$SELECT public.admin_open_lobby(id) FROM public.rooms WHERE status = 'CREATED'$$,
  'Admin opens lobby'
);

SELECT lives_ok(
  $$SELECT public.admin_start_game(id) FROM public.rooms WHERE status = 'LOBBY'$$,
  'Admin starts game'
);

-- 2. Add business 'b1' and upgrade to level 1 for Team Alpha
-- Default b1: cost 200, initial_cv 200, u1_cost 150, u1_cv 300
-- Initial team state: cash = 1500, cv = 0
-- After add b1 (apply_purchase = true): cash = 1300, cv = 200
-- After upgrade b1 to 1 (apply_upgrade = true): cash = 1150, cv = 500
SELECT lives_ok(
  $$SELECT public.admin_add_business(
      (SELECT id FROM public.teams WHERE slot = 1),
      'b1',
      true,
      0
  )$$,
  'Add business b1 to Team Alpha'
);

SELECT lives_ok(
  $$SELECT public.admin_set_business_level(
      (SELECT id FROM public.teams WHERE slot = 1),
      'b1',
      1::smallint,
      true,
      1
  )$$,
  'Upgrade business b1 to level 1 for Team Alpha'
);

-- 3. Verify admin_remove_business with CORRECTION deducts CV (floored at 0)
-- Should deduct initial_cv (200) + u1_cv (300) = 500 CV. Resulting CV = 0. Cash unchanged (1150).
SELECT is(
  (
    SELECT (res->'team'->>'cv')::int
    FROM (
      SELECT public.admin_remove_business(
        (SELECT id FROM public.teams WHERE slot = 1),
        'b1',
        'CORRECTION',
        false,
        2
      ) AS res
    ) sub
  ),
  0,
  'admin_remove_business with CORRECTION deducts initial + upgrade CV back to 0'
);

-- 4. Declare Team Beta bankrupt: verifies cash is set to 0 and is_bankrupt is true
SELECT is(
  (
    SELECT jsonb_build_object('cash', (res->'team'->>'cash')::int, 'is_bankrupt', (res->'team'->>'is_bankrupt')::boolean)
    FROM (
      SELECT public.admin_set_bankrupt(
        (SELECT id FROM public.teams WHERE slot = 2),
        true,
        0
      ) AS res
    ) sub
  ),
  '{"cash": 0, "is_bankrupt": true}'::jsonb,
  'admin_set_bankrupt(true) sets cash to 0 and is_bankrupt to true'
);

-- 5. Mutation blocking on bankrupt team
-- admin_adjust on bankrupt Team Beta raises TEAM_BANKRUPT
SELECT throws_ok(
  $$SELECT public.admin_adjust(
      jsonb_build_array(
        jsonb_build_object(
          'team_id', (SELECT id FROM public.teams WHERE slot = 2),
          'cash_delta', 100,
          'cv_delta', 100,
          'expected_version', 1
        )
      ),
      'Test adjustment'
  )$$,
  'TEAM_BANKRUPT',
  'admin_adjust rejects mutations on bankrupt team'
);

-- admin_set_team_values on bankrupt Team Beta raises TEAM_BANKRUPT
SELECT throws_ok(
  $$SELECT public.admin_set_team_values(
      (SELECT id FROM public.teams WHERE slot = 2),
      500,
      500,
      1
  )$$,
  'TEAM_BANKRUPT',
  'admin_set_team_values rejects mutations on bankrupt team'
);

SELECT * FROM finish();

ROLLBACK;
