-- ============================================================
-- Photos d'exercices : à coller UNE fois dans Supabase > SQL Editor, puis « Run ».
-- Crée le dossier public « photos » : tout le monde peut voir les photos,
-- seul le coach connecté peut en ajouter, modifier ou supprimer.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true;

drop policy if exists "photos coach ajout" on storage.objects;
drop policy if exists "photos coach modif" on storage.objects;
drop policy if exists "photos coach suppr" on storage.objects;

create policy "photos coach ajout" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.est_coach());
create policy "photos coach modif" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and public.est_coach());
create policy "photos coach suppr" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.est_coach());
