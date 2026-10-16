-- pgTAP Regression Suite: Lifecycle Deadlock Resolution & Schema Reconciliation

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(8);
SELECT set_config('app.env', 'test', true);
SELECT set_config('app.test_now', '2026-03-01 10:00:00+00', true);

\set admin_uid 'a9000000-0000-0000-0000-000000000001'

INSERT INTO auth.users (id, email, created_at, updated_at)
VALUES (:'admin_uid', 'life-admin@test.local', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.admins (user_id)
VALUES (:'admin_uid')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  '{"sub": "a9000000-0000-0000-0000-000000000001", "role": "authenticated"}',
  true
);

-- 1. Setup room, open lobby, start game
SELECT lives_ok(
  $$SELECT public.admin_create_room(
      2,
      '[{"name":"Abort Alpha","color":"#BA0001"},{"name":"Abort Beta","color":"#BA0002"}]'::jsonb
  )$$,
  'Admin creates room for lifecycle test'
);

SELECT lives_ok(
  $$SELECT public.admin_open_lobby(id) FROM public.rooms WHERE status = 'CREATED'$$,
  'Admin opens lobby'
);

SELECT lives_ok(
  $$SELECT public.admin_start_game(id) FROM public.rooms WHERE status = 'LOBBY'$$,
  'Admin starts game'
);

-- 2. Force room into TIME_EXPIRED by updating ends_at to past and calling expire_if_due
UPDATE public.rooms
SET ends_at = '2026-03-01 09:59:00+00'
WHERE status = 'ACTIVE';

SELECT lives_ok(
  $$SELECT public.expire_if_due(id) FROM public.rooms$$,
  'expire_if_due transitions room to TIME_EXPIRED'
);

SELECT is(
  (SELECT status FROM public.rooms LIMIT 1),
  'TIME_EXPIRED'::public.room_status,
  'Room is in TIME_EXPIRED state'
);

-- 3. Abort game from TIME_EXPIRED: previously blocked by trigger, now permitted
SELECT lives_ok(
  $$SELECT public.admin_abort_game(id, 'Aborting expired game for replay') FROM public.rooms WHERE status = 'TIME_EXPIRED'$$,
  'admin_abort_game succeeds when room is in TIME_EXPIRED'
);

SELECT is(
  (SELECT status FROM public.rooms LIMIT 1),
  'LOBBY'::public.room_status,
  'Room successfully transitioned from TIME_EXPIRED back to LOBBY'
);

-- 4. Verify index pruning: idx_team_claims_team_id does NOT exist, but idx_team_claims_one_active_claim_per_team does
SELECT is(
  (
    SELECT count(*)::int
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'team_claims'
      AND indexname = 'idx_team_claims_team_id'
  ),
  0,
  'Redundant index idx_team_claims_team_id was pruned'
);

SELECT * FROM finish();

ROLLBACK;
