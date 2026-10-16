-- Migration 0017: Game Accounting & Company Value (CV) Integrity
-- 1. CV Deduction on Correction: In admin_remove_business, when reason = 'CORRECTION',
--    deduct initial_cv and all upgrade CV associated with the removed business (floored at 0).
-- 2. Bankruptcy Cash Depletion: In admin_set_bankrupt, when value = true, explicitly set
--    cash = 0 in accordance with rulebook bankruptcy rules.
-- 3. Bankrupt Team Mutation Blocking: In admin_adjust and admin_set_team_values, reject
--    direct financial adjustments on bankrupt teams with TEAM_BANKRUPT.

BEGIN;

-- 1. admin_remove_business: Deduct CV on CORRECTION, maintain cash credit on FORCED_SALE
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
  v_cv int;
  v_curr_level smallint;
  v_cost int;
  v_initial_cv int;
  v_u1_cv int;
  v_u2_cv int;
  v_cv_deduction int := 0;
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

  IF reason = 'CORRECTION' THEN
    v_is_correction := true;
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

  v_prev := jsonb_build_object('business_key', business_key, 'level', v_curr_level, 'cash', v_cash, 'cv', v_cv);

  DELETE FROM public.team_businesses
  WHERE team_businesses.team_id = admin_remove_business.team_id
    AND team_businesses.business_key = admin_remove_business.business_key;

  IF reason = 'FORCED_SALE' AND credit_resale THEN
    SELECT cost INTO v_cost FROM public.business_catalog WHERE key = business_key;
    v_cash := v_cash + v_cost;
  ELSIF reason = 'CORRECTION' THEN
    SELECT initial_cv, u1_cv, u2_cv INTO v_initial_cv, v_u1_cv, v_u2_cv
    FROM public.business_catalog
    WHERE key = business_key;

    v_cv_deduction := v_initial_cv;
    IF v_curr_level >= 1 THEN
      v_cv_deduction := v_cv_deduction + v_u1_cv;
    END IF;
    IF v_curr_level >= 2 THEN
      v_cv_deduction := v_cv_deduction + v_u2_cv;
    END IF;

    v_cv := greatest(0, v_cv - v_cv_deduction);
  END IF;

  UPDATE public.teams
  SET cash = v_cash,
      cv = v_cv,
      version = version + 1
  WHERE id = team_id;

  v_new := jsonb_build_object(
    'business_key', business_key,
    'reason', reason,
    'credit_resale', credit_resale,
    'cash', v_cash,
    'cv', v_cv
  );

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

-- 2. admin_set_bankrupt: Zero cash upon bankruptcy declaration
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
  v_curr_cash int;
  v_biz RECORD;
  v_is_correction boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    PERFORM public.raise_error('NOT_ADMIN');
  END IF;

  IF request_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.activity_events WHERE activity_events.request_id = admin_set_bankrupt.request_id) THEN
    RETURN public.get_team_snapshot(team_id);
  END IF;

  SELECT t.room_id, t.version, t.is_bankrupt, t.cash
  INTO v_room_id, v_curr_ver, v_curr_bankrupt, v_curr_cash
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

    UPDATE public.teams
    SET cash = 0,
        is_bankrupt = true,
        version = version + 1
    WHERE id = team_id;
  ELSE
    UPDATE public.teams
    SET is_bankrupt = false,
        version = version + 1
    WHERE id = team_id;
  END IF;

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
    jsonb_build_object('is_bankrupt', v_curr_bankrupt, 'cash', v_curr_cash),
    jsonb_build_object('is_bankrupt', value, 'cash', CASE WHEN value THEN 0 ELSE v_curr_cash END),
    note,
    v_is_correction,
    auth.uid(),
    public.app_now()
  );

  RETURN public.get_team_snapshot(team_id);
END;
$$;

-- 3. admin_adjust: Reject adjustments on bankrupt teams
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
  v_curr_bankrupt boolean;
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

    SELECT version, cash, cv, is_bankrupt INTO v_curr_ver, v_curr_cash, v_curr_cv, v_curr_bankrupt
    FROM public.teams
    WHERE id = v_team_id
    FOR UPDATE;

    IF v_curr_bankrupt THEN
      PERFORM public.raise_error('TEAM_BANKRUPT', jsonb_build_object('team_id', v_team_id));
    END IF;

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

-- 4. admin_set_team_values: Reject value override on bankrupt teams
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
  v_curr_bankrupt boolean;
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

  SELECT version, teams.cash, teams.cv, teams.is_bankrupt
  INTO v_curr_version, v_curr_cash, v_curr_cv, v_curr_bankrupt
  FROM public.teams
  WHERE id = team_id
  FOR UPDATE;

  IF v_curr_bankrupt THEN
    PERFORM public.raise_error('TEAM_BANKRUPT');
  END IF;

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

GRANT EXECUTE ON FUNCTION public.admin_remove_business(uuid, text, text, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_bankrupt(uuid, boolean, int, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust(jsonb, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_team_values(uuid, int, int, int, uuid, text) TO authenticated;

COMMIT;
