-- pgTAP Regression Suite: Concurrency, Idempotency & Optimistic Locking Guarantees

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(8);
SELECT set_config('app.env', 'test', true);
SELECT set_config('app.test_now', '2026-03-01 10:00:00+00', true);

\set admin_uid 'aa000000-0000-0000-0000-000000000001'

INSERT INTO auth.users (id, email, created_at, updated_at)
VALUES (:'admin_uid', 'conc-admin@test.local', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.admins (user_id)
VALUES (:'admin_uid')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "aa000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

-- 1. Setup room, open lobby, start game
SELECT lives_ok(
  $$SELECT public.admin_create_room(
      2,
      '[{"name":"Conc Alpha","color":"#BA0001"},{"name":"Conc Beta","color":"#BA0002"}]'::jsonb
  )$$,
  'Admin creates room for concurrency stress test'
);

SELECT lives_ok(
  $$SELECT public.admin_open_lobby(id) FROM public.rooms WHERE status = 'CREATED'$$,
  'Admin opens lobby'
);

SELECT lives_ok(
  $$SELECT public.admin_start_game(id) FROM public.rooms WHERE status = 'LOBBY'$$,
  'Admin starts game'
);

-- 2. Idempotency on admin_set_team_values:
-- Execute set cash = 1200 with request_id 'r1'
\set req_id '11111111-1111-4111-8111-111111111111'
SELECT lives_ok(
  $$SELECT public.admin_set_team_values(
      (SELECT id FROM public.teams WHERE slot = 1),
      1200,
      NULL,
      0,
      '11111111-1111-4111-8111-111111111111'::uuid,
      'Initial cash setup'
  )$$,
  'First execution with request_id succeeds'
);

-- Replay identical request_id: must succeed idempotently without error and without re-incrementing version
SELECT is(
  (
    SELECT (res->'team'->>'version')::int
    FROM (
      SELECT public.admin_set_team_values(
        (SELECT id FROM public.teams WHERE slot = 1),
        1200,
        NULL,
        0,
        '11111111-1111-4111-8111-111111111111'::uuid,
        'Initial cash setup'
      ) AS res
    ) sub
  ),
  1,
  'Replay of admin_set_team_values with duplicate request_id returns snapshot without re-incrementing version'
);

-- 3. Idempotency on admin_adjust:
\set adjust_req_id '22222222-2222-4222-8222-222222222222'
SELECT lives_ok(
  $$SELECT public.admin_adjust(
      jsonb_build_array(
        jsonb_build_object(
          'team_id', (SELECT id FROM public.teams WHERE slot = 1),
          'cash_delta', 100,
          'cv_delta', 50,
          'expected_version', 1
        )
      ),
      'RENT',
      'Rent payment',
      '22222222-2222-4222-8222-222222222222'::uuid
  )$$,
  'admin_adjust succeeds with request_id'
);

SELECT is(
  (
    SELECT (res->>'status')
    FROM (
      SELECT public.admin_adjust(
        jsonb_build_array(
          jsonb_build_object(
            'team_id', (SELECT id FROM public.teams WHERE slot = 1),
            'cash_delta', 100,
            'cv_delta', 50,
            'expected_version', 1
          )
        ),
        'RENT',
        'Duplicate rent replay',
        '22222222-2222-4222-8222-222222222222'::uuid
      ) AS res
    ) sub
  ),
  'idempotent_duplicate',
  'Duplicate admin_adjust request_id returns idempotent_duplicate without double-applying cash'
);

-- 4. Optimistic locking: Stale expected_version must be rejected with VERSION_CONFLICT
SELECT throws_ok(
  $$SELECT public.admin_set_team_values(
      (SELECT id FROM public.teams WHERE slot = 1),
      9999,
      NULL,
      1, -- Current version is 2
      '33333333-3333-4333-8333-333333333333'::uuid
  )$$,
  'VERSION_CONFLICT',
  'Stale expected_version throws VERSION_CONFLICT'
);

SELECT * FROM finish();

ROLLBACK;
