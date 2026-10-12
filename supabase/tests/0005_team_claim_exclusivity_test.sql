-- pgTAP Regression Suite: one active anonymous claim per team

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(5);
SELECT set_config('app.env', 'test', true);
SELECT set_config('app.test_now', '2026-03-01 10:00:00+00', true);

\set admin_uid 'a4000000-0000-0000-0000-000000000001'
\set player_one 'b4000000-0000-0000-0000-000000000001'
\set player_two 'b4000000-0000-0000-0000-000000000002'

INSERT INTO auth.users (id, email, created_at, updated_at)
VALUES
  (:'admin_uid', 'claims-admin@test.local', now(), now()),
  (:'player_one', 'claims-player-one@test.local', now(), now()),
  (:'player_two', 'claims-player-two@test.local', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.admins (user_id)
VALUES (:'admin_uid')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "a4000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

SELECT lives_ok(
  $$SELECT public.admin_create_room(
      5,
      '[{"name":"Claim A","color":"#AA0001"},{"name":"Claim B","color":"#AA0002"},
        {"name":"Claim C","color":"#AA0003"},{"name":"Claim D","color":"#AA0004"},
        {"name":"Claim E","color":"#AA0005"}]'::jsonb
  )$$,
  'Admin creates room for claim exclusivity test'
);

SELECT lives_ok(
  $$SELECT public.admin_open_lobby(id) FROM public.rooms WHERE status = 'CREATED'$$,
  'Admin opens lobby for claim exclusivity test'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub": "b4000000-0000-0000-0000-000000000001", "role": "authenticated"}',
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
  'First phone claims team slot successfully'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub": "b4000000-0000-0000-0000-000000000002", "role": "authenticated"}',
  true
);

SELECT throws_ok(
  $$SELECT public.join_team(
      r.code,
      1,
      (SELECT ts.join_pin FROM public.team_secrets ts JOIN public.teams t ON t.id = ts.team_id WHERE t.room_id = r.id AND t.slot = 1)
  )
  FROM public.rooms r
  WHERE r.status = 'LOBBY'$$,
  'P0001',
  'TEAM_ALREADY_CLAIMED',
  'Second phone cannot claim an already-connected team'
);

SELECT is(
  (SELECT count(*)::int
   FROM public.team_claims tc
   JOIN public.teams t ON t.id = tc.team_id
   WHERE t.slot = 1),
  1,
  'Exactly one active claim remains for the team'
);

SELECT * FROM finish();
ROLLBACK;
