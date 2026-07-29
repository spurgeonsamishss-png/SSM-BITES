-- =========================================================================
-- SSM BITES — SUPABASE STORAGE BUCKETS
-- Run AFTER 01_schema.sql and 02_rls_policies.sql
-- =========================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('food-images',    'food-images',    true,  5242880,  array['image/png','image/jpeg','image/webp']),
  ('student-avatars','student-avatars',true,  2097152,  array['image/png','image/jpeg']),
  ('admin-avatars',  'admin-avatars',  true,  2097152,  array['image/png','image/jpeg']),
  ('app-logos',      'app-logos',      true,  2097152,  array['image/png','image/jpeg','image/svg+xml']),
  ('banners',        'banners',        true,  5242880,  array['image/png','image/jpeg','image/webp']),
  ('review-images',  'review-images',  true,  5242880,  array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

-- ---------- food-images: admin/super_admin write, everyone read ----------
create policy "food_images_public_read" on storage.objects for select
  using (bucket_id = 'food-images');
create policy "food_images_admin_write" on storage.objects for insert
  with check (bucket_id = 'food-images' and is_admin_or_super());
create policy "food_images_admin_update" on storage.objects for update
  using (bucket_id = 'food-images' and is_admin_or_super());
create policy "food_images_admin_delete" on storage.objects for delete
  using (bucket_id = 'food-images' and is_admin_or_super());

-- ---------- student-avatars: owner writes their own folder (auth.uid()/*) ----------
create policy "student_avatars_public_read" on storage.objects for select
  using (bucket_id = 'student-avatars');
create policy "student_avatars_owner_write" on storage.objects for insert
  with check (bucket_id = 'student-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "student_avatars_owner_update" on storage.objects for update
  using (bucket_id = 'student-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "student_avatars_owner_delete" on storage.objects for delete
  using (bucket_id = 'student-avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- admin-avatars: owner or super_admin writes ----------
create policy "admin_avatars_public_read" on storage.objects for select
  using (bucket_id = 'admin-avatars');
create policy "admin_avatars_owner_write" on storage.objects for insert
  with check (bucket_id = 'admin-avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_super_admin()));
create policy "admin_avatars_owner_update" on storage.objects for update
  using (bucket_id = 'admin-avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_super_admin()));

-- ---------- app-logos / banners: super_admin managed, public read ----------
create policy "app_logos_public_read" on storage.objects for select
  using (bucket_id = 'app-logos');
create policy "app_logos_super_admin_write" on storage.objects for all
  using (bucket_id = 'app-logos' and is_super_admin())
  with check (bucket_id = 'app-logos' and is_super_admin());

create policy "banners_public_read" on storage.objects for select
  using (bucket_id = 'banners');
create policy "banners_admin_write" on storage.objects for all
  using (bucket_id = 'banners' and is_admin_or_super())
  with check (bucket_id = 'banners' and is_admin_or_super());

-- ---------- review-images: student uploads to their own folder, public read ----------
create policy "review_images_public_read" on storage.objects for select
  using (bucket_id = 'review-images');
create policy "review_images_owner_write" on storage.objects for insert
  with check (bucket_id = 'review-images' and (storage.foldername(name))[1] = auth.uid()::text);
