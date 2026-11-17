-- ============================================================
-- CoachPlan : base de données Supabase
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- On peut le relancer sans problème : il ne crée que ce qui manque.
-- ============================================================

-- 1. Qui est le coach (seulement les comptes listés ici voient tout)
create table if not exists public.coachs (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.coachs enable row level security;

create or replace function public.est_coach() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.coachs where user_id = auth.uid());
$$;

-- 2. Les tables : chaque élément est gardé tel quel (colonne data)
create table if not exists public.clients (
  id text primary key,
  data jsonb not null,
  code text generated always as (data->>'code') stored,
  updated_at timestamptz not null default now()
);
create unique index if not exists clients_code on public.clients (code);

create table if not exists public.exercices (
  id text primary key, data jsonb not null, updated_at timestamptz not null default now()
);
create table if not exists public.recettes (
  id text primary key, data jsonb not null, updated_at timestamptz not null default now()
);
create table if not exists public.reglages (
  id text primary key, data jsonb not null, updated_at timestamptz not null default now()
);
create table if not exists public.programmes (
  id text primary key, data jsonb not null,
  client_id text generated always as (data->>'clientId') stored,
  updated_at timestamptz not null default now()
);
create table if not exists public.seances (
  id text primary key, data jsonb not null,
  client_id text generated always as (data->>'clientId') stored,
  updated_at timestamptz not null default now()
);
create table if not exists public.plans_nutrition (
  id text primary key, data jsonb not null,
  client_id text generated always as (data->>'clientId') stored,
  updated_at timestamptz not null default now()
);
create index if not exists programmes_client on public.programmes (client_id);
create index if not exists seances_client on public.seances (client_id);
create index if not exists plans_client on public.plans_nutrition (client_id);

-- 3. Sécurité : seul le coach connecté lit et modifie les tables directement
do $$
declare t text;
begin
  foreach t in array array['clients','exercices','recettes','reglages','programmes','seances','plans_nutrition'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists coach_tout on public.%I', t);
    execute format('create policy coach_tout on public.%I for all to authenticated using (public.est_coach()) with check (public.est_coach())', t);
  end loop;
end $$;

-- 4. Accès du client avec son lien (?code=…) : seulement SES données
create or replace function public.client_par_code(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select id from public.clients
  where p_code is not null and length(p_code) >= 8 and code = p_code
    and coalesce((data->>'actif')::boolean, true)
  limit 1;
$$;
revoke all on function public.client_par_code(text) from public, anon, authenticated;

create or replace function public.client_donnees(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cid text := public.client_par_code(p_code);
begin
  if cid is null then return null; end if;
  return jsonb_build_object(
    'clients',        (select coalesce(jsonb_agg(data - 'notes'), '[]'::jsonb) from public.clients where id = cid),
    'exercices',      (select coalesce(jsonb_agg(data), '[]'::jsonb) from public.exercices),
    'recettes',       (select coalesce(jsonb_agg(data), '[]'::jsonb) from public.recettes),
    'programmes',     (select coalesce(jsonb_agg(data), '[]'::jsonb) from public.programmes where client_id = cid),
    'seances',        (select coalesce(jsonb_agg(data), '[]'::jsonb) from public.seances where client_id = cid),
    'plansNutrition', (select coalesce(jsonb_agg(data), '[]'::jsonb) from public.plans_nutrition where client_id = cid),
    'reglages',       coalesce((select data from public.reglages where id = 'reglages'), '{}'::jsonb)
  );
end $$;

create or replace function public.client_enregistrer(p_code text, p_table text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare cid text := public.client_par_code(p_code);
begin
  if cid is null then raise exception 'Lien invalide'; end if;
  if p_data->>'clientId' is distinct from cid or p_data->>'id' is distinct from p_id then
    raise exception 'Accès refusé';
  end if;
  if p_table = 'seances' then
    if exists (select 1 from public.seances where id = p_id and client_id is distinct from cid) then raise exception 'Accès refusé'; end if;
    insert into public.seances (id, data) values (p_id, p_data)
      on conflict (id) do update set data = excluded.data, updated_at = now();
  elsif p_table = 'programmes' then
    if exists (select 1 from public.programmes where id = p_id and client_id is distinct from cid) then raise exception 'Accès refusé'; end if;
    insert into public.programmes (id, data) values (p_id, p_data)
      on conflict (id) do update set data = excluded.data, updated_at = now();
  else
    raise exception 'Table non permise';
  end if;
end $$;

create or replace function public.client_supprimer(p_code text, p_table text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare cid text := public.client_par_code(p_code);
begin
  if cid is null then raise exception 'Lien invalide'; end if;
  if p_table <> 'seances' then raise exception 'Table non permise'; end if;
  delete from public.seances where id = p_id and client_id = cid;
end $$;

grant execute on function public.client_donnees(text) to anon, authenticated;
grant execute on function public.client_enregistrer(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.client_supprimer(text, text, text) to anon, authenticated;

-- 5. Bibliothèque d'exercices de départ (n'écrase pas tes modifications)
insert into public.exercices (id, data) values
  ('ex1', $ex${"id": "ex1", "nom": "3/4 Sit-Up", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/3_4_Sit-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex2', $ex${"id": "ex2", "nom": "Ab Crunch Machine", "categorie": "Core", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Ab_Crunch_Machine/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex3', $ex${"id": "ex3", "nom": "Ab Wheel Rollout", "categorie": "Core", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Ab_Roller/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex4', $ex${"id": "ex4", "nom": "Air Bike Crunch", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Air_Bike/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex5', $ex${"id": "ex5", "nom": "Alternating Dumbbell Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Alternate_Bicep_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex6', $ex${"id": "ex6", "nom": "Alternating Hammer Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Alternate_Hammer_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex7', $ex${"id": "ex7", "nom": "Arnold Press", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Arnold_Dumbbell_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex8', $ex${"id": "ex8", "nom": "Back Extension", "categorie": "Dos", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hyperextensions_Back_Extensions/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex9', $ex${"id": "ex9", "nom": "Band External Rotation", "categorie": "Épaules", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/External_Rotation_with_Band/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex10', $ex${"id": "ex10", "nom": "Band Lateral Raise", "categorie": "Épaules", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Lateral_Raise_-_With_Bands/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex11', $ex${"id": "ex11", "nom": "Band Pull-Apart", "categorie": "Épaules", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Band_Pull_Apart/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex12', $ex${"id": "ex12", "nom": "Band-Assisted Pull-Up", "categorie": "Dos", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Band_Assisted_Pull-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex13', $ex${"id": "ex13", "nom": "Banded Good Morning", "categorie": "Ischio-jambiers", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Band_Good_Morning/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex14', $ex${"id": "ex14", "nom": "Banded Hip Extension", "categorie": "Fessiers", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hip_Extension_with_Bands/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex15', $ex${"id": "ex15", "nom": "Banded Squat", "categorie": "Quadriceps", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Squats_-_With_Bands/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex16', $ex${"id": "ex16", "nom": "Barbell Calf Raise", "categorie": "Mollets", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Barbell_Calf_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex17', $ex${"id": "ex17", "nom": "Barbell Curl", "categorie": "Biceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex18', $ex${"id": "ex18", "nom": "Barbell Glute Bridge", "categorie": "Fessiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Glute_Bridge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex19', $ex${"id": "ex19", "nom": "Barbell Lunge", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex20', $ex${"id": "ex20", "nom": "Barbell Rollout", "categorie": "Core", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Ab_Rollout/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex21', $ex${"id": "ex21", "nom": "Barbell Shrug", "categorie": "Épaules", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Shrug/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex22', $ex${"id": "ex22", "nom": "Barbell Side Split Squat", "categorie": "Fessiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Side_Split_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex23', $ex${"id": "ex23", "nom": "Barbell Step-Up", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Step_Ups/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex24', $ex${"id": "ex24", "nom": "Barbell Upright Row", "categorie": "Épaules", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Upright_Barbell_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex25', $ex${"id": "ex25", "nom": "Barbell Walking Lunge", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Walking_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex26', $ex${"id": "ex26", "nom": "Bench Dips", "categorie": "Triceps", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bench_Dips/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex27', $ex${"id": "ex27", "nom": "Bench Leg Raise", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Flat_Bench_Lying_Leg_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex28', $ex${"id": "ex28", "nom": "Bench Press", "categorie": "Poitrine", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Bench_Press_-_Medium_Grip/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex29', $ex${"id": "ex29", "nom": "Bent-Knee Hip Raise", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bent-Knee_Hip_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex30', $ex${"id": "ex30", "nom": "Bent-Over Barbell Row", "categorie": "Dos", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bent_Over_Barbell_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex31', $ex${"id": "ex31", "nom": "Bent-Over Dumbbell Row", "categorie": "Dos", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bent_Over_Two-Dumbbell_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex32', $ex${"id": "ex32", "nom": "Biceps Curl Machine", "categorie": "Biceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Machine_Bicep_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex33', $ex${"id": "ex33", "nom": "Bodyweight Squat", "categorie": "Quadriceps", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bodyweight_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex34', $ex${"id": "ex34", "nom": "Boxe", "categorie": "Cardio", "equipement": "—", "image": "", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex35', $ex${"id": "ex35", "nom": "Cable Chest Press", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Chest_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex36', $ex${"id": "ex36", "nom": "Cable Crunch", "categorie": "Core", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Crunch/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex37', $ex${"id": "ex37", "nom": "Cable Curl", "categorie": "Biceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Biceps_Cable_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex38', $ex${"id": "ex38", "nom": "Cable Deadlift", "categorie": "Ischio-jambiers", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Deadlifts/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex39', $ex${"id": "ex39", "nom": "Cable Front Raise", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Front_Cable_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex40', $ex${"id": "ex40", "nom": "Cable Glute Kickback", "categorie": "Fessiers", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One-Legged_Cable_Kickback/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex41', $ex${"id": "ex41", "nom": "Cable Hip Adduction", "categorie": "Fessiers", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Hip_Adduction/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex42', $ex${"id": "ex42", "nom": "Cable Lateral Raise", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Seated_Lateral_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex43', $ex${"id": "ex43", "nom": "Cable Preacher Curl", "categorie": "Biceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Preacher_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex44', $ex${"id": "ex44", "nom": "Cable Pull-Through", "categorie": "Fessiers", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Pull_Through/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex45', $ex${"id": "ex45", "nom": "Cable Rear Delt Fly", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Rear_Delt_Fly/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex46', $ex${"id": "ex46", "nom": "Cable Russian Twist", "categorie": "Core", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Russian_Twists/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex47', $ex${"id": "ex47", "nom": "Cable Shoulder Press", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Shoulder_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex48', $ex${"id": "ex48", "nom": "Cable Shrug", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Shrugs/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex49', $ex${"id": "ex49", "nom": "Cable Upright Row", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Upright_Cable_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex50', $ex${"id": "ex50", "nom": "Cable Wood Chop", "categorie": "Core", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Cable_Wood_Chop/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex51', $ex${"id": "ex51", "nom": "Cable Wrist Curl", "categorie": "Avant-bras", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Wrist_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex52', $ex${"id": "ex52", "nom": "Calf Press Machine", "categorie": "Mollets", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Calf_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex53', $ex${"id": "ex53", "nom": "Calf Raise on Dumbbell", "categorie": "Mollets", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Calf_Raise_On_A_Dumbbell/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex54', $ex${"id": "ex54", "nom": "Chest Dips", "categorie": "Poitrine", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dips_-_Chest_Version/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex55', $ex${"id": "ex55", "nom": "Chest Press Machine", "categorie": "Poitrine", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leverage_Chest_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex56', $ex${"id": "ex56", "nom": "Chest-Supported Rear Delt Raise", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bent_Over_Dumbbell_Rear_Delt_Raise_With_Head_On_Bench/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex57', $ex${"id": "ex57", "nom": "Chest-Supported T-Bar Row", "categorie": "Dos", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Lying_T-Bar_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex58', $ex${"id": "ex58", "nom": "Chin-Up", "categorie": "Dos", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Chin-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex59', $ex${"id": "ex59", "nom": "Close-Grip Barbell Curl", "categorie": "Biceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Close-Grip_Standing_Barbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex60', $ex${"id": "ex60", "nom": "Close-Grip Bench Press", "categorie": "Triceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Close-Grip_Barbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex61', $ex${"id": "ex61", "nom": "Close-Grip Dumbbell Press", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Close-Grip_Dumbbell_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex62', $ex${"id": "ex62", "nom": "Close-Grip Lat Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Close-Grip_Front_Lat_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex63', $ex${"id": "ex63", "nom": "Close-Grip Push-Up", "categorie": "Triceps", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Push-Ups_-_Close_Triceps_Position/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex64', $ex${"id": "ex64", "nom": "Concentration Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Concentration_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex65', $ex${"id": "ex65", "nom": "Corde à sauter", "categorie": "Cardio", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Rope_Jumping/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex66', $ex${"id": "ex66", "nom": "Course à pied", "categorie": "Cardio", "equipement": "—", "image": "", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex67', $ex${"id": "ex67", "nom": "Cross-Body Hammer Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cross_Body_Hammer_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex68', $ex${"id": "ex68", "nom": "Crossover Reverse Lunge", "categorie": "Fessiers", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Crossover_Reverse_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex69', $ex${"id": "ex69", "nom": "Crunch", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Crunches/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex70', $ex${"id": "ex70", "nom": "Dead Bug", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dead_Bug/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex71', $ex${"id": "ex71", "nom": "Deadlift", "categorie": "Dos", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex72', $ex${"id": "ex72", "nom": "Decline Barbell Bench Press", "categorie": "Poitrine", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Decline_Barbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex73', $ex${"id": "ex73", "nom": "Decline Crunch", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Decline_Crunch/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex74', $ex${"id": "ex74", "nom": "Decline Dumbbell Press", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Decline_Dumbbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex75', $ex${"id": "ex75", "nom": "Dip Machine", "categorie": "Triceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dip_Machine/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex76', $ex${"id": "ex76", "nom": "Donkey Calf Raise", "categorie": "Mollets", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Donkey_Calf_Raises/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex77', $ex${"id": "ex77", "nom": "Dumbbell Bench Press", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex78', $ex${"id": "ex78", "nom": "Dumbbell Box Squat", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Squat_To_A_Bench/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex79', $ex${"id": "ex79", "nom": "Dumbbell Calf Raise", "categorie": "Mollets", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Dumbbell_Calf_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex80', $ex${"id": "ex80", "nom": "Dumbbell Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Bicep_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex81', $ex${"id": "ex81", "nom": "Dumbbell Fly", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Flyes/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex82', $ex${"id": "ex82", "nom": "Dumbbell Front Raise", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Front_Dumbbell_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex83', $ex${"id": "ex83", "nom": "Dumbbell Lunge", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Lunges/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex84', $ex${"id": "ex84", "nom": "Dumbbell Pullover", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Straight-Arm_Dumbbell_Pullover/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex85', $ex${"id": "ex85", "nom": "Dumbbell Reverse Curl", "categorie": "Avant-bras", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Dumbbell_Reverse_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex86', $ex${"id": "ex86", "nom": "Dumbbell Reverse Lunge", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Rear_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex87', $ex${"id": "ex87", "nom": "Dumbbell Scaption", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Scaption/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex88', $ex${"id": "ex88", "nom": "Dumbbell Shoulder Press", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Shoulder_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex89', $ex${"id": "ex89", "nom": "Dumbbell Shrug", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Shrug/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex90', $ex${"id": "ex90", "nom": "Dumbbell Side Bend", "categorie": "Core", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Side_Bend/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex91', $ex${"id": "ex91", "nom": "Dumbbell Split Squat", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Split_Squat_with_Dumbbells/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex92', $ex${"id": "ex92", "nom": "Dumbbell Squat", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex93', $ex${"id": "ex93", "nom": "Dumbbell Step-Up", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Step_Ups/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex94', $ex${"id": "ex94", "nom": "Dumbbell Stiff-Leg Deadlift", "categorie": "Ischio-jambiers", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Stiff-Legged_Dumbbell_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex95', $ex${"id": "ex95", "nom": "Dumbbell Triceps Kickback", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Tricep_Dumbbell_Kickback/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex96', $ex${"id": "ex96", "nom": "Dumbbell Upright Row", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Dumbbell_Upright_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex97', $ex${"id": "ex97", "nom": "Dumbbell Walking Lunge", "categorie": "Quadriceps", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bodyweight_Walking_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex98', $ex${"id": "ex98", "nom": "Elbow-to-Knee", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Elbow_to_Knee/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex99', $ex${"id": "ex99", "nom": "Elevated Reverse Lunge", "categorie": "Fessiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Elevated_Back_Lunge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex100', $ex${"id": "ex100", "nom": "Elliptique", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Elliptical_Trainer/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex101', $ex${"id": "ex101", "nom": "Escalier", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Stairmaster/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex102', $ex${"id": "ex102", "nom": "Escalier ou vélo", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Stairmaster/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex103', $ex${"id": "ex103", "nom": "Escalier roulant (Step mill)", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Step_Mill/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex104', $ex${"id": "ex104", "nom": "EZ-Bar Curl", "categorie": "Biceps", "equipement": "EZ Bar", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/EZ-Bar_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex105', $ex${"id": "ex105", "nom": "Face Pull", "categorie": "Épaules", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Face_Pull/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex106', $ex${"id": "ex106", "nom": "Feet-Elevated Push-Up", "categorie": "Poitrine", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Push-Ups_With_Feet_Elevated/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex107', $ex${"id": "ex107", "nom": "Finger Curl", "categorie": "Avant-bras", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Finger_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex108', $ex${"id": "ex108", "nom": "Flat Bench Cable Fly", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Flat_Bench_Cable_Flyes/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex109', $ex${"id": "ex109", "nom": "Flutter Kicks", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Flutter_Kicks/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex110', $ex${"id": "ex110", "nom": "Front Squat", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Front_Squat_Clean_Grip/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex111', $ex${"id": "ex111", "nom": "Full Squat", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Full_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex112', $ex${"id": "ex112", "nom": "Glute Bridge", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Butt_Lift_Bridge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex113', $ex${"id": "ex113", "nom": "Glute Kickback", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Glute_Kickback/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex114', $ex${"id": "ex114", "nom": "Glute Leg Lift", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leg_Lift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex115', $ex${"id": "ex115", "nom": "Glute-Ham Raise", "categorie": "Ischio-jambiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Natural_Glute_Ham_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex116', $ex${"id": "ex116", "nom": "Goblet Squat", "categorie": "Quadriceps", "equipement": "Kettlebell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Goblet_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex117', $ex${"id": "ex117", "nom": "Good Morning", "categorie": "Ischio-jambiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Good_Morning/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex118', $ex${"id": "ex118", "nom": "Grimpeurs", "categorie": "Cardio", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Mountain_Climbers/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex119', $ex${"id": "ex119", "nom": "Hack Squat", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hack_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex120', $ex${"id": "ex120", "nom": "Hammer Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hammer_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex121', $ex${"id": "ex121", "nom": "Hanging Leg Raise", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hanging_Leg_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex122', $ex${"id": "ex122", "nom": "Hanging Pike", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hanging_Pike/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex123', $ex${"id": "ex123", "nom": "High Cable Crossover", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Crossover/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex124', $ex${"id": "ex124", "nom": "High Cable Curl", "categorie": "Biceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/High_Cable_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex125', $ex${"id": "ex125", "nom": "High Row Machine", "categorie": "Dos", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leverage_High_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex126', $ex${"id": "ex126", "nom": "Hip Abductor", "categorie": "Fessiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Thigh_Abductor/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex127', $ex${"id": "ex127", "nom": "Hip Adductor", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Thigh_Adductor/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex128', $ex${"id": "ex128", "nom": "Hip Thrust", "categorie": "Fessiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Hip_Thrust/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex129', $ex${"id": "ex129", "nom": "Hyperextension", "categorie": "Ischio-jambiers", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Hyperextensions_Back_Extensions/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex130', $ex${"id": "ex130", "nom": "Incline Bench Press", "categorie": "Poitrine", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Incline_Bench_Press_-_Medium_Grip/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex131', $ex${"id": "ex131", "nom": "Incline Cable Fly", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Incline_Cable_Flye/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex132', $ex${"id": "ex132", "nom": "Incline Cable RDL", "categorie": "Ischio-jambiers", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Pull_Through/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex133', $ex${"id": "ex133", "nom": "Incline Dumbbell Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Incline_Dumbbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex134', $ex${"id": "ex134", "nom": "Incline Dumbbell Fly", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Incline_Dumbbell_Flyes/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex135', $ex${"id": "ex135", "nom": "Incline Dumbbell Press", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Incline_Dumbbell_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex136', $ex${"id": "ex136", "nom": "Incline Dumbbell Row", "categorie": "Dos", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Incline_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex137', $ex${"id": "ex137", "nom": "Incline Push-Up", "categorie": "Poitrine", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Incline_Push-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex138', $ex${"id": "ex138", "nom": "Iso Row Machine", "categorie": "Dos", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leverage_Iso_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex139', $ex${"id": "ex139", "nom": "Jackknife Sit-Up", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Jackknife_Sit-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex140', $ex${"id": "ex140", "nom": "JM Press", "categorie": "Triceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/JM_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex141', $ex${"id": "ex141", "nom": "Jogging sur tapis roulant", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Jogging_Treadmill/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex142', $ex${"id": "ex142", "nom": "Kettlebell Halo", "categorie": "Épaules", "equipement": "Kettlebell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Kettlebell_Halo/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex143', $ex${"id": "ex143", "nom": "Kettlebell Plank", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Plank/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex144', $ex${"id": "ex144", "nom": "Kettlebell Swing", "categorie": "Ischio-jambiers", "equipement": "Kettlebell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One-Arm_Kettlebell_Swings/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex145', $ex${"id": "ex145", "nom": "Kettlebell Windmill", "categorie": "Core", "equipement": "Kettlebell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Kettlebell_Windmill/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex146', $ex${"id": "ex146", "nom": "Kneeling Cable Triceps Extension", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Kneeling_Cable_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex147', $ex${"id": "ex147", "nom": "Kneeling High Cable Row", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Kneeling_High_Pulley_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex148', $ex${"id": "ex148", "nom": "Lat Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Wide-Grip_Lat_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex149', $ex${"id": "ex149", "nom": "Lateral Raise", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Side_Lateral_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex150', $ex${"id": "ex150", "nom": "Leg Extension", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leg_Extensions/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex151', $ex${"id": "ex151", "nom": "Leg Press (1 Leg)", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leg_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex152', $ex${"id": "ex152", "nom": "Leg Press (2 Legs)", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leg_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex153', $ex${"id": "ex153", "nom": "Leg Press (High Feet)", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leg_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex154', $ex${"id": "ex154", "nom": "Leg Press Calf Raise", "categorie": "Mollets", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Calf_Press_On_The_Leg_Press_Machine/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex155', $ex${"id": "ex155", "nom": "Leverage Shoulder Press", "categorie": "Épaules", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Leverage_Shoulder_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex156', $ex${"id": "ex156", "nom": "Low Cable Crossover", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Low_Cable_Crossover/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex157', $ex${"id": "ex157", "nom": "Low Cable Triceps Extension", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Low_Cable_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex158', $ex${"id": "ex158", "nom": "Lying Dumbbell Triceps Extension", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Lying_Dumbbell_Tricep_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex159', $ex${"id": "ex159", "nom": "Lying Leg Curl", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Lying_Leg_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex160', $ex${"id": "ex160", "nom": "Lying Squat Machine", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Lying_Machine_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex161', $ex${"id": "ex161", "nom": "Machine Bench Press", "categorie": "Poitrine", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Machine_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex162', $ex${"id": "ex162", "nom": "Marche", "categorie": "Cardio", "equipement": "—", "image": "", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex163', $ex${"id": "ex163", "nom": "Marche sur tapis roulant", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Walking_Treadmill/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex164', $ex${"id": "ex164", "nom": "Monster Walk", "categorie": "Fessiers", "equipement": "Band", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Monster_Walk/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex165', $ex${"id": "ex165", "nom": "Narrow-Stance Leg Press", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Narrow_Stance_Leg_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex166', $ex${"id": "ex166", "nom": "Natation", "categorie": "Cardio", "equipement": "—", "image": "", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex167', $ex${"id": "ex167", "nom": "Neck Isometric (Front/Back)", "categorie": "Autre", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Isometric_Neck_Exercise_-_Front_And_Back/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex168', $ex${"id": "ex168", "nom": "Neck Isometric (Side)", "categorie": "Autre", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Isometric_Neck_Exercise_-_Sides/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex169', $ex${"id": "ex169", "nom": "Oblique Crunch", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Oblique_Crunches/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex170', $ex${"id": "ex170", "nom": "One-Arm Dumbbell Bench Press", "categorie": "Poitrine", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One_Arm_Dumbbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex171', $ex${"id": "ex171", "nom": "One-Arm Dumbbell Row", "categorie": "Dos", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One-Arm_Dumbbell_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex172', $ex${"id": "ex172", "nom": "One-Arm Dumbbell Triceps Extension", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_One-Arm_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex173', $ex${"id": "ex173", "nom": "One-Arm Lat Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One_Arm_Lat_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex174', $ex${"id": "ex174", "nom": "One-Arm Lateral Raise", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One-Arm_Side_Laterals/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex175', $ex${"id": "ex175", "nom": "One-Arm Preacher Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/One_Arm_Dumbbell_Preacher_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex176', $ex${"id": "ex176", "nom": "One-Arm Seated Cable Row", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_One-arm_Cable_Pulley_Rows/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex177', $ex${"id": "ex177", "nom": "Overhead Cable Curl", "categorie": "Biceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Overhead_Cable_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex178', $ex${"id": "ex178", "nom": "Overhead Rope Triceps Extension", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Rope_Overhead_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex179', $ex${"id": "ex179", "nom": "Pallof Press", "categorie": "Core", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Pallof_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex180', $ex${"id": "ex180", "nom": "Palms-Down Wrist Curl", "categorie": "Avant-bras", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Palms-Down_Wrist_Curl_Over_A_Bench/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex181', $ex${"id": "ex181", "nom": "Palms-Up Wrist Curl", "categorie": "Avant-bras", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Palms-Up_Barbell_Wrist_Curl_Over_A_Bench/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex182', $ex${"id": "ex182", "nom": "Pec Deck", "categorie": "Poitrine", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Butterfly/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex183', $ex${"id": "ex183", "nom": "Plank", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Plank/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex184', $ex${"id": "ex184", "nom": "Plié Dumbbell Squat", "categorie": "Quadriceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Plie_Dumbbell_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex185', $ex${"id": "ex185", "nom": "Preacher Curl", "categorie": "Biceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Preacher_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex186', $ex${"id": "ex186", "nom": "Preacher Curl Machine", "categorie": "Biceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Machine_Preacher_Curls/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex187', $ex${"id": "ex187", "nom": "Pull-Up", "categorie": "Dos", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Pullups/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex188', $ex${"id": "ex188", "nom": "Push-Up", "categorie": "Poitrine", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Pushups/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex189', $ex${"id": "ex189", "nom": "Rameur", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Rowing_Stationary/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex190', $ex${"id": "ex190", "nom": "Rear Delt Fly", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Flyes/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex191', $ex${"id": "ex191", "nom": "Reverse Barbell Curl", "categorie": "Biceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Barbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex192', $ex${"id": "ex192", "nom": "Reverse Crunch", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Crunch/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex193', $ex${"id": "ex193", "nom": "Reverse Curl (Forearms)", "categorie": "Avant-bras", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Barbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex194', $ex${"id": "ex194", "nom": "Reverse Hyperextension", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Hyperextension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex195', $ex${"id": "ex195", "nom": "Reverse Pec Deck", "categorie": "Épaules", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Machine_Flyes/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex196', $ex${"id": "ex196", "nom": "Reverse-Grip Bent-Over Row", "categorie": "Dos", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Grip_Bent-Over_Rows/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex197', $ex${"id": "ex197", "nom": "Reverse-Grip Triceps Pushdown", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Reverse_Grip_Triceps_Pushdown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex198', $ex${"id": "ex198", "nom": "Romanian Deadlift", "categorie": "Ischio-jambiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Romanian_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex199', $ex${"id": "ex199", "nom": "Rope Crunch", "categorie": "Core", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Rope_Crunch/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex200', $ex${"id": "ex200", "nom": "Rope Hammer Curl", "categorie": "Biceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Cable_Hammer_Curls_-_Rope_Attachment/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex201', $ex${"id": "ex201", "nom": "Rope Straight-Arm Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Rope_Straight-Arm_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex202', $ex${"id": "ex202", "nom": "Rope Triceps Pushdown", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Triceps_Pushdown_-_Rope_Attachment/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex203', $ex${"id": "ex203", "nom": "Russian Twist", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Russian_Twist/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex204', $ex${"id": "ex204", "nom": "Scissor Kick", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Scissor_Kick/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex205', $ex${"id": "ex205", "nom": "Seated Barbell Military Press", "categorie": "Épaules", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Barbell_Military_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex206', $ex${"id": "ex206", "nom": "Seated Cable Row", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Cable_Rows/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex207', $ex${"id": "ex207", "nom": "Seated Calf Raise", "categorie": "Mollets", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Calf_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex208', $ex${"id": "ex208", "nom": "Seated Dumbbell Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Dumbbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex209', $ex${"id": "ex209", "nom": "Seated Dumbbell Shoulder Press", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Dumbbell_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex210', $ex${"id": "ex210", "nom": "Seated Dumbbell Triceps Extension", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Triceps_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex211', $ex${"id": "ex211", "nom": "Seated Dumbbell Wrist Curl", "categorie": "Avant-bras", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Dumbbell_Palms-Up_Wrist_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex212', $ex${"id": "ex212", "nom": "Seated Lateral Raise", "categorie": "Épaules", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Side_Lateral_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex213', $ex${"id": "ex213", "nom": "Seated Leg Curl", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Seated_Leg_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex214', $ex${"id": "ex214", "nom": "Shotgun Row", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Shotgun_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex215', $ex${"id": "ex215", "nom": "Shoulder Press Machine", "categorie": "Épaules", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Machine_Shoulder_Military_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex216', $ex${"id": "ex216", "nom": "Side Plank", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Side_Bridge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex217', $ex${"id": "ex217", "nom": "Single-Leg Extension", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Single-Leg_Leg_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex218', $ex${"id": "ex218", "nom": "Single-Leg Glute Bridge", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Single_Leg_Glute_Bridge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex219', $ex${"id": "ex219", "nom": "Single-Leg Romanian Deadlift", "categorie": "Ischio-jambiers", "equipement": "Kettlebell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Kettlebell_One-Legged_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex220', $ex${"id": "ex220", "nom": "Single-Leg Seated Calf Raise", "categorie": "Mollets", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dumbbell_Seated_One-Leg_Calf_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex221', $ex${"id": "ex221", "nom": "Sit-Up", "categorie": "Core", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Sit-Up/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex222', $ex${"id": "ex222", "nom": "Skull Crusher", "categorie": "Triceps", "equipement": "EZ Bar", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/EZ-Bar_Skullcrusher/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex223', $ex${"id": "ex223", "nom": "Smith Machine Bench Press", "categorie": "Poitrine", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex224', $ex${"id": "ex224", "nom": "Smith Machine Bent-Over Row", "categorie": "Dos", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Bent_Over_Row/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex225', $ex${"id": "ex225", "nom": "Smith Machine Calf Raise", "categorie": "Mollets", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Calf_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex226', $ex${"id": "ex226", "nom": "Smith Machine Incline Press", "categorie": "Poitrine", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Incline_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex227', $ex${"id": "ex227", "nom": "Smith Machine Leg Press", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Leg_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex228', $ex${"id": "ex228", "nom": "Smith Machine Shoulder Press", "categorie": "Épaules", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Overhead_Shoulder_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex229', $ex${"id": "ex229", "nom": "Smith Machine Split Squat", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Single-Leg_Split_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex230', $ex${"id": "ex230", "nom": "Smith Machine Squat", "categorie": "Quadriceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex231', $ex${"id": "ex231", "nom": "Smith Machine Stiff-Leg Deadlift", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Smith_Machine_Stiff-Legged_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex232', $ex${"id": "ex232", "nom": "Spider Curl", "categorie": "Biceps", "equipement": "EZ Bar", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Spider_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex233', $ex${"id": "ex233", "nom": "Squat", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Barbell_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex234', $ex${"id": "ex234", "nom": "Stability Ball Crunch", "categorie": "Core", "equipement": "Ball", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Exercise_Ball_Crunch/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex235', $ex${"id": "ex235", "nom": "Stability Ball Hip Bridge", "categorie": "Fessiers", "equipement": "Ball", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Physioball_Hip_Bridge/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex236', $ex${"id": "ex236", "nom": "Stability Ball Leg Curl", "categorie": "Ischio-jambiers", "equipement": "Ball", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Ball_Leg_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex237', $ex${"id": "ex237", "nom": "Standing Cable Chest Press", "categorie": "Poitrine", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Cable_Chest_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex238', $ex${"id": "ex238", "nom": "Standing Calf Raise", "categorie": "Mollets", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Calf_Raises/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex239', $ex${"id": "ex239", "nom": "Standing Dumbbell Triceps Extension", "categorie": "Triceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Dumbbell_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex240', $ex${"id": "ex240", "nom": "Standing Leg Curl", "categorie": "Ischio-jambiers", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Leg_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex241', $ex${"id": "ex241", "nom": "Standing Military Press", "categorie": "Épaules", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Standing_Military_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex242', $ex${"id": "ex242", "nom": "Step-Up with Knee Raise", "categorie": "Fessiers", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Step-up_with_Knee_Raise/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex243', $ex${"id": "ex243", "nom": "Stiff-Leg Deadlift", "categorie": "Ischio-jambiers", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Stiff-Legged_Barbell_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex244', $ex${"id": "ex244", "nom": "Straight-Arm Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Straight-Arm_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex245', $ex${"id": "ex245", "nom": "Sumo Deadlift", "categorie": "Dos", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Sumo_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex246', $ex${"id": "ex246", "nom": "Superman", "categorie": "Dos", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Superman/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex247', $ex${"id": "ex247", "nom": "T-Bar Row", "categorie": "Dos", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/T-Bar_Row_with_Handle/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex248', $ex${"id": "ex248", "nom": "Tapis roulant", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Running_Treadmill/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex249', $ex${"id": "ex249", "nom": "Trap Bar Deadlift", "categorie": "Dos", "equipement": "Other", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Trap_Bar_Deadlift/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex250', $ex${"id": "ex250", "nom": "Triceps Dips", "categorie": "Triceps", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Dips_-_Triceps_Version/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex251', $ex${"id": "ex251", "nom": "Triceps Extension Machine", "categorie": "Triceps", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Machine_Triceps_Extension/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex252', $ex${"id": "ex252", "nom": "Triceps Pushdown", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Triceps_Pushdown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex253', $ex${"id": "ex253", "nom": "Underhand Lat Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Underhand_Cable_Pulldowns/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex254', $ex${"id": "ex254", "nom": "V-Bar Pulldown", "categorie": "Dos", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/V-Bar_Pulldown/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex255', $ex${"id": "ex255", "nom": "V-Bar Triceps Pushdown", "categorie": "Triceps", "equipement": "Cable", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Triceps_Pushdown_-_V-Bar_Attachment/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex256', $ex${"id": "ex256", "nom": "Vélo", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Bicycling_Stationary/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex257', $ex${"id": "ex257", "nom": "Vélo semi-couché", "categorie": "Cardio", "equipement": "Machine", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Recumbent_Bike/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex258', $ex${"id": "ex258", "nom": "Vélo à air (assault bike)", "categorie": "Cardio", "equipement": "Bodyweight", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Air_Bike/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex259', $ex${"id": "ex259", "nom": "Wide-Grip Barbell Curl", "categorie": "Biceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Wide-Grip_Standing_Barbell_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex260', $ex${"id": "ex260", "nom": "Wide-Grip Bench Press", "categorie": "Poitrine", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Wide-Grip_Barbell_Bench_Press/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex261', $ex${"id": "ex261", "nom": "Wide-Stance Squat", "categorie": "Quadriceps", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Wide_Stance_Barbell_Squat/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex262', $ex${"id": "ex262", "nom": "Wrist Rotation", "categorie": "Avant-bras", "equipement": "Barbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Wrist_Rotations_with_Straight_Bar/0.jpg", "video": "", "consignes": ""}$ex$::jsonb),
  ('ex263', $ex${"id": "ex263", "nom": "Zottman Curl", "categorie": "Biceps", "equipement": "Dumbbell", "image": "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/Zottman_Curl/0.jpg", "video": "", "consignes": ""}$ex$::jsonb)
on conflict (id) do nothing;

-- 6. TOI comme coach : remplace le courriel par celui de ton compte
--    (créé dans Authentication > Users), puis relance seulement ces 2 lignes.
insert into public.coachs (user_id)
select id from auth.users where email = 'dacostacalderon@gmail.com' on conflict do nothing;
