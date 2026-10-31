-- Migration 0034: Register admin user 99555f62-d188-48a5-b366-394e51bb42cd
-- STARTUPOLY Live Scoreboard & Game Management System

INSERT INTO public.admins (user_id)
VALUES ('99555f62-d188-48a5-b366-394e51bb42cd')
ON CONFLICT (user_id) DO NOTHING;
