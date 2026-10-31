-- Run this query in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/psyruoujpaitwiembsex/sql/new

INSERT INTO public.admins (user_id)
VALUES ('99555f62-d188-48a5-b366-394e51bb42cd')
ON CONFLICT (user_id) DO NOTHING;
