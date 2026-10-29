-- Provision manasvig43@gmail.com as Admin in Supabase
DO $$
DECLARE
  v_user_id uuid;
  v_email text := 'manasvig43@gmail.com';
  v_password text := 'manas@123';
  v_encrypted_pw text;
BEGIN
  -- 1. Generate encrypted password
  v_encrypted_pw := extensions.crypt(v_password, extensions.gen_salt('bf'));

  -- 2. Check if user already exists in auth.users
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      v_encrypted_pw,
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb,
      now(),
      now(),
      encode(gen_random_bytes(32), 'hex')
    );
  ELSE
    -- If user already exists, update password and confirm email
    UPDATE auth.users
    SET encrypted_password = v_encrypted_pw,
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        updated_at = now()
    WHERE id = v_user_id;
  END IF;

  -- 3. Ensure registered in public.admins
  INSERT INTO public.admins (user_id)
  VALUES (v_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE 'Admin % (ID: %) successfully provisioned!', v_email, v_user_id;
END;
$$;
