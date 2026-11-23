-- تفعيل إضافة توليد المعرفات الفريدة UUID
create extension if not exists "pgcrypto";

-- ==========================================
-- 1. جدول المؤسسات الجامعية والبحثية المعتمدة (institutions)
-- ==========================================
create table if not exists public.institutions (
    id uuid primary key default gen_random_uuid(),
    acronym text not null,
    name_fr text not null unique,
    category text not null check (category in ('Université / Centre Universitaire', 'Annexe Universitaire', 'École Nationale Supérieure', 'Institut / Centre de Recherche')),
    region text not null check (region in ('Centre', 'Est', 'Ouest', 'Sud', 'National')),
    wilaya text,
    is_active boolean not null default true,
    created_at timestamptz not null default now()
);

-- ==========================================
-- 2. جدول ملفات المساهمين والباحثين (profiles)
-- ==========================================
create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    contributor_code text unique,
    full_name text not null,
    email text unique,
    date_of_birth date,
    institution_id uuid references public.institutions(id) on delete set null,
    department_or_specialty text,
    id_document_path text,
    academic_proof_path text,
    role text not null default 'contributor' check (role in ('admin', 'curator', 'contributor')),
    is_verified boolean not null default false,
    bio text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- التأكد من وجود الأعمدة الجديدة في حال كان الجدول منشأً مسبقاً
alter table public.profiles
add column if not exists date_of_birth date,
add column if not exists id_document_path text,
add column if not exists academic_proof_path text;

-- ==========================================
-- 3. جدول العزلات البكتيرية (isolates)
-- ==========================================
create table if not exists public.isolates (
    id uuid primary key default gen_random_uuid(),
    isolate_code text not null unique,
    genus text not null,
    species text,
    strain_designation text,
    source_type text,
    isolation_source_detail text,
    wilaya text,
    location_description text,
    latitude double precision,
    longitude double precision,
    collection_date date,
    gram_stain text,
    phenotype_notes text,
    status text not null default 'pending' check (status in ('pending', 'verified', 'archived')),
    contributor_id uuid not null references public.profiles(id) on delete restrict,
    verified_by uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ==========================================
-- 4. جدول التسلسلات الجينية (sequences)
-- ==========================================
create table if not exists public.sequences (
    id uuid primary key default gen_random_uuid(),
    isolate_id uuid not null references public.isolates(id) on delete cascade,
    sequence_type text not null default '16S_rRNA',
    accession_number text,
    sequence_length integer generated always as (length(regexp_replace(nucleotide_seq, '\s+', '', 'g'))) stored,
    nucleotide_seq text not null,
    fasta_header text,
    quality_notes text,
    contributor_id uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ==========================================
-- 5. تسلسلات توليد أكواد غير متكررة لا تُعاد
-- ==========================================
create sequence if not exists public.contributor_code_seq start 1 increment 1;
create sequence if not exists public.isolate_code_seq start 1 increment 1;

create or replace function public.assign_contributor_code()
returns trigger
language plpgsql
as $$
begin
    if new.contributor_code is null or btrim(new.contributor_code) = '' then
        new.contributor_code := 'DZB-C-' || lpad(nextval('public.contributor_code_seq')::text, 4, '0');
    else
        new.contributor_code := upper(btrim(new.contributor_code));
    end if;
    return new;
end;
$$;

drop trigger if exists set_contributor_code on public.profiles;
create trigger set_contributor_code
before insert on public.profiles
for each row execute function public.assign_contributor_code();

create or replace function public.assign_isolate_code()
returns trigger
language plpgsql
as $$
begin
    if new.isolate_code is null or btrim(new.isolate_code) = '' then
        new.isolate_code := 'DZB-ISO-' || lpad(nextval('public.isolate_code_seq')::text, 6, '0');
    else
        new.isolate_code := upper(btrim(new.isolate_code));
    end if;
    return new;
end;
$$;

drop trigger if exists set_isolate_code on public.isolates;
create trigger set_isolate_code
before insert on public.isolates
for each row execute function public.assign_isolate_code();

-- ==========================================
-- 6. ربط إنشاء المستخدم في auth.users بجدول profiles تلقائياً
-- ==========================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
    insert into public.profiles (
        id,
        full_name,
        email,
        date_of_birth,
        institution_id,
        department_or_specialty,
        id_document_path,
        academic_proof_path
    )
    values (
        new.id,
        coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
        new.email,
        nullif(new.raw_user_meta_data ->> 'date_of_birth', '')::date,
        nullif(new.raw_user_meta_data ->> 'institution_id', '')::uuid,
        nullif(btrim(new.raw_user_meta_data ->> 'department_or_specialty'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'id_document_path'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'academic_proof_path'), '')
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- ==========================================
-- 7. فهارس لتسريع البحث والفرز
-- ==========================================
create index if not exists idx_institutions_category on public.institutions (category);
create index if not exists idx_institutions_region on public.institutions (region);
create index if not exists idx_profiles_institution on public.profiles (institution_id);
create index if not exists idx_isolates_genus_species on public.isolates (genus, species);
create index if not exists idx_isolates_wilaya on public.isolates (wilaya);
create index if not exists idx_isolates_status on public.isolates (status);
create index if not exists idx_isolates_contributor on public.isolates (contributor_id);
create index if not exists idx_sequences_isolate on public.sequences (isolate_id);
create index if not exists idx_sequences_type on public.sequences (sequence_type);

-- ==========================================
-- 8. دالة تحديث تاريخ التعديل تلقائياً
-- ==========================================
create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.handle_updated_at();

drop trigger if exists set_isolates_updated_at on public.isolates;
create trigger set_isolates_updated_at
before update on public.isolates
for each row execute function public.handle_updated_at();

drop trigger if exists set_sequences_updated_at on public.sequences;
create trigger set_sequences_updated_at
before update on public.sequences
for each row execute function public.handle_updated_at();

-- ==========================================
-- 9. تفعيل نظام الصلاحيات (Row Level Security)
-- ==========================================
alter table public.institutions enable row level security;
alter table public.profiles enable row level security;
alter table public.isolates enable row level security;
alter table public.sequences enable row level security;

drop policy if exists "Institutions are viewable by everyone" on public.institutions;
create policy "Institutions are viewable by everyone"
on public.institutions for select
using (is_active = true);

drop policy if exists "Public profiles are viewable by everyone" on public.profiles;
create policy "Public profiles are viewable by everyone"
on public.profiles for select
using (true);

drop policy if exists "Users can insert their own profile" on public.profiles;
create policy "Users can insert their own profile"
on public.profiles for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "Verified isolates are viewable by everyone" on public.isolates;
create policy "Verified isolates are viewable by everyone"
on public.isolates for select
using (
    status = 'verified'
    or (auth.uid() is not null and contributor_id = auth.uid())
);

drop policy if exists "Authenticated contributors can insert isolates" on public.isolates;
create policy "Authenticated contributors can insert isolates"
on public.isolates for insert
to authenticated
with check (auth.uid() = contributor_id);

drop policy if exists "Contributors can update their own isolates" on public.isolates;
create policy "Contributors can update their own isolates"
on public.isolates for update
to authenticated
using (auth.uid() = contributor_id)
with check (auth.uid() = contributor_id);

drop policy if exists "Contributors can delete their own isolates" on public.isolates;
create policy "Contributors can delete their own isolates"
on public.isolates for delete
to authenticated
using (auth.uid() = contributor_id);

drop policy if exists "Sequences of accessible isolates are viewable" on public.sequences;
create policy "Sequences of accessible isolates are viewable"
on public.sequences for select
using (
    exists (
        select 1 from public.isolates i
        where i.id = sequences.isolate_id
        and (
            i.status = 'verified'
            or (auth.uid() is not null and i.contributor_id = auth.uid())
        )
    )
);

drop policy if exists "Authenticated contributors can insert sequences" on public.sequences;
create policy "Authenticated contributors can insert sequences"
on public.sequences for insert
to authenticated
with check (auth.uid() = contributor_id);

drop policy if exists "Contributors can update their own sequences" on public.sequences;
create policy "Contributors can update their own sequences"
on public.sequences for update
to authenticated
using (auth.uid() = contributor_id)
with check (auth.uid() = contributor_id);

drop policy if exists "Contributors can delete their own sequences" on public.sequences;
create policy "Contributors can delete their own sequences"
on public.sequences for delete
to authenticated
using (auth.uid() = contributor_id);

-- ==========================================
-- 10. مخزن الوثائق الثبوتية الخاص (verification-docs)
-- ==========================================
insert into storage.buckets (id, name, public)
values ('verification-docs', 'verification-docs', false)
on conflict (id) do nothing;

drop policy if exists "Users upload own verification docs" on storage.objects;
create policy "Users upload own verification docs"
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'verification-docs'
    and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Users read own verification docs" on storage.objects;
create policy "Users read own verification docs"
on storage.objects for select
to authenticated
using (
    bucket_id = 'verification-docs'
    and (storage.foldername(name))[1] = auth.uid()::text
);

-- ==========================================
-- 11. إدخال كافة الجامعات والمدارس العليا والمعاهد المعتمدة
-- ==========================================
insert into public.institutions (acronym, name_fr, category, region, wilaya) values
('USTHB', 'Université des Sciences et de la Technologie Houari Boumediene', 'Université / Centre Universitaire', 'Centre', 'Alger'),
('Univ. Alger 1', 'Université d''Alger 1 Benyoucef Benkhedda (Faculté de Médecine et de Pharmacie)', 'Université / Centre Universitaire', 'Centre', 'Alger'),
('USDB', 'Université Saad Dahlab Blida 1', 'Université / Centre Universitaire', 'Centre', 'Blida'),
('UAMOB', 'Université Akli Mohand Oulhadj de Bouira', 'Université / Centre Universitaire', 'Centre', 'Bouira'),
('UMMTO', 'Université Mouloud Mammeri de Tizi-Ouzou', 'Université / Centre Universitaire', 'Centre', 'Tizi Ouzou'),
('UMBB', 'Université M''Hamed Bougara de Boumerdès', 'Université / Centre Universitaire', 'Centre', 'Boumerdès'),
('CU Tipaza', 'Centre Universitaire Morsli Abdellah de Tipaza', 'Université / Centre Universitaire', 'Centre', 'Tipaza'),
('UYFM', 'Université Yahia Farès de Médéa', 'Université / Centre Universitaire', 'Centre', 'Médéa'),
('UDBKM', 'Université Djilali Bounaama de Khemis Miliana', 'Université / Centre Universitaire', 'Centre', 'Aïn Defla'),
('UZAJ', 'Université Ziane Achour de Djelfa', 'Université / Centre Universitaire', 'Centre', 'Djelfa'),

('UFMC1', 'Université Frères Mentouri Constantine 1', 'Université / Centre Universitaire', 'Est', 'Constantine'),
('UC3', 'Université Salah Boubnider Constantine 3', 'Université / Centre Universitaire', 'Est', 'Constantine'),
('UFAS1', 'Université Ferhat Abbas Sétif 1', 'Université / Centre Universitaire', 'Est', 'Sétif'),
('UBMA', 'Université Badji Mokhtar Annaba', 'Université / Centre Universitaire', 'Est', 'Annaba'),
('UAMB', 'Université Abderrahmane Mira de Béjaïa', 'Université / Centre Universitaire', 'Est', 'Béjaïa'),
('Univ. M''sila', 'Université Mohamed Boudiaf de M''sila', 'Université / Centre Universitaire', 'Est', 'M''sila'),
('UB2', 'Université Mustapha Ben Boulaïd Batna 2', 'Université / Centre Universitaire', 'Est', 'Batna'),
('UB1', 'Université Hadj Lakhdar Batna 1', 'Université / Centre Universitaire', 'Est', 'Batna'),
('Univ. Jijel', 'Université Mohammed Seddik Benyahia de Jijel', 'Université / Centre Universitaire', 'Est', 'Jijel'),
('Univ. Skikda', 'Université du 20 Août 1955 de Skikda', 'Université / Centre Universitaire', 'Est', 'Skikda'),
('Univ. Guelma', 'Université 8 Mai 1945 de Guelma', 'Université / Centre Universitaire', 'Est', 'Guelma'),
('Univ. El Tarf', 'Université Chadli Bendjedid d''El Tarf', 'Université / Centre Universitaire', 'Est', 'El Tarf'),
('Univ. Souk Ahras', 'Université Mohamed Chérif Messaadia de Souk Ahras', 'Université / Centre Universitaire', 'Est', 'Souk Ahras'),
('Univ. Tébessa', 'Université Larbi Tébessi de Tébessa', 'Université / Centre Universitaire', 'Est', 'Tébessa'),
('Univ. Oum El Bouaghi', 'Université Larbi Ben M''hidi d''Oum El Bouaghi', 'Université / Centre Universitaire', 'Est', 'Oum El Bouaghi'),
('Univ. Khenchela', 'Université Abbes Laghrour de Khenchela', 'Université / Centre Universitaire', 'Est', 'Khenchela'),
('Univ. BBA', 'Université Mohamed El Bachir El Ibrahimi de Bordj Bou Arréridj', 'Université / Centre Universitaire', 'Est', 'Bordj Bou Arréridj'),
('CU Mila', 'Centre Universitaire Abdelhafid Boussouf de Mila', 'Université / Centre Universitaire', 'Est', 'Mila'),
('UMKB', 'Université Mohamed Khider de Biskra', 'Université / Centre Universitaire', 'Est', 'Biskra'),
('Univ. El Oued', 'Université Echahid Hamma Lakhdar d''El Oued', 'Université / Centre Universitaire', 'Est', 'El Oued'),

('Univ. Oran 1', 'Université d''Oran 1 Ahmed Ben Bella', 'Université / Centre Universitaire', 'Ouest', 'Oran'),
('UABT', 'Université Abou Bekr Belkaïd de Tlemcen', 'Université / Centre Universitaire', 'Ouest', 'Tlemcen'),
('UDL', 'Université Djillali Liabès de Sidi Bel Abbès', 'Université / Centre Universitaire', 'Ouest', 'Sidi Bel Abbès'),
('UMAB', 'Université Abdelhamid Ibn Badis de Mostaganem', 'Université / Centre Universitaire', 'Ouest', 'Mostaganem'),
('UHBC', 'Université Hassiba Benbouali de Chlef', 'Université / Centre Universitaire', 'Ouest', 'Chlef'),
('Univ. Tiaret', 'Université Ibn Khaldoun de Tiaret', 'Université / Centre Universitaire', 'Ouest', 'Tiaret'),
('Univ. Mascara', 'Université Mustapha Stambouli de Mascara', 'Université / Centre Universitaire', 'Ouest', 'Mascara'),
('Univ. Saïda', 'Université Dr. Moulay Tahar de Saïda', 'Université / Centre Universitaire', 'Ouest', 'Saïda'),
('Univ. Aïn Témouchent', 'Université Belhadj Bouchaib d''Aïn Témouchent', 'Université / Centre Universitaire', 'Ouest', 'Aïn Témouchent'),
('Univ. Relizane', 'Université Ahmed Zabana de Relizane', 'Université / Centre Universitaire', 'Ouest', 'Relizane'),
('Univ. Tissemsilt', 'Université Ahmed Ben Yahia El Wancharissi de Tissemsilt', 'Université / Centre Universitaire', 'Ouest', 'Tissemsilt'),

('UKMO', 'Université Kasdi Merbah d''Ouargla', 'Université / Centre Universitaire', 'Sud', 'Ouargla'),
('UATL', 'Université Amar Telidji de Laghouat', 'Université / Centre Universitaire', 'Sud', 'Laghouat'),
('Univ. Ghardaïa', 'Université de Ghardaïa', 'Université / Centre Universitaire', 'Sud', 'Ghardaïa'),
('UTMB', 'Université Tahri Mohammed de Béchar', 'Université / Centre Universitaire', 'Sud', 'Béchar'),
('Univ. Adrar', 'Université Ahmed Draïa d''Adrar', 'Université / Centre Universitaire', 'Sud', 'Adrar'),
('Univ. Tamanrasset', 'Université Amine Elokkal El Hadj Moussa Eg Akhamouk de Tamanrasset', 'Université / Centre Universitaire', 'Sud', 'Tamanrasset'),
('CU Naâma', 'Centre Universitaire Salhi Ahmed de Naâma', 'Université / Centre Universitaire', 'Sud', 'Naâma'),
('CU El Bayadh', 'Centre Universitaire Nour Bachir d''El Bayadh', 'Université / Centre Universitaire', 'Sud', 'El Bayadh'),
('CU Tindouf', 'Centre Universitaire Ali Kafi de Tindouf', 'Université / Centre Universitaire', 'Sud', 'Tindouf'),
('CU Illizi', 'Centre Universitaire Cheikh Amoud Ben Mokhtar d''Illizi', 'Université / Centre Universitaire', 'Sud', 'Illizi'),

('Annexe Univ. Timimoun', 'Annexe Universitaire de Timimoun', 'Annexe Universitaire', 'Sud', 'Timimoun'),
('Annexe Univ. Bordj Badji Mokhtar', 'Annexe Universitaire de Bordj Badji Mokhtar', 'Annexe Universitaire', 'Sud', 'Bordj Badji Mokhtar'),
('Annexe Univ. Ouled Djellal', 'Annexe Universitaire d''Ouled Djellal', 'Annexe Universitaire', 'Sud', 'Ouled Djellal'),
('Annexe Univ. Béni Abbès', 'Annexe Universitaire de Béni Abbès', 'Annexe Universitaire', 'Sud', 'Béni Abbès'),
('Annexe Univ. In Salah', 'Annexe Universitaire d''In Salah', 'Annexe Universitaire', 'Sud', 'In Salah'),
('Annexe Univ. In Guezzam', 'Annexe Universitaire d''In Guezzam', 'Annexe Universitaire', 'Sud', 'In Guezzam'),
('Annexe Univ. Touggourt', 'Annexe Universitaire de Touggourt', 'Annexe Universitaire', 'Sud', 'Touggourt'),
('Annexe Univ. Djanet', 'Annexe Universitaire de Djanet', 'Annexe Universitaire', 'Sud', 'Djanet'),
('Annexe Univ. El M''Ghair', 'Annexe Universitaire d''El M''Ghair', 'Annexe Universitaire', 'Sud', 'El M''Ghair'),
('Annexe Univ. El Meniaa', 'Annexe Universitaire d''El Meniaa', 'Annexe Universitaire', 'Sud', 'El Meniaa'),

('ESSBO', 'École Supérieure des Sciences Biologiques d''Oran', 'École Nationale Supérieure', 'Ouest', 'Oran'),
('ENSB', 'École Nationale Supérieure de Biotechnologie (Constantine)', 'École Nationale Supérieure', 'Est', 'Constantine'),
('ENSA', 'École Nationale Supérieure Agronomique (El Harrach, Alger)', 'École Nationale Supérieure', 'Centre', 'Alger'),
('ESAM', 'École Supérieure d''Agronomie de Mostaganem', 'École Nationale Supérieure', 'Ouest', 'Mostaganem'),
('ESSAIA', 'École Supérieure des Sciences de l''Aliment et des Industries Agroalimentaires (Alger)', 'École Nationale Supérieure', 'Centre', 'Alger'),
('ENSV', 'École Nationale Supérieure Vétérinaire (Alger)', 'École Nationale Supérieure', 'Centre', 'Alger'),
('ENSSMAL', 'École Nationale Supérieure des Sciences de la Mer et de l''Aménagement du Littoral (Alger)', 'École Nationale Supérieure', 'Centre', 'Alger'),
('ENSF', 'École Nationale Supérieure des Forêts (Khenchela)', 'École Nationale Supérieure', 'Est', 'Khenchela'),
('ENSH', 'École Nationale Supérieure d''Hydraulique (Blida)', 'École Nationale Supérieure', 'Centre', 'Blida'),
('ENS Kouba', 'École Normale Supérieure de Kouba (Dépt. Sciences Naturelles, Alger)', 'École Nationale Supérieure', 'Centre', 'Alger'),
('ENS Constantine', 'École Normale Supérieure Assia Djebar de Constantine (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Est', 'Constantine'),
('ENS Ouargla', 'École Normale Supérieure d''Ouargla (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Sud', 'Ouargla'),
('ENS Laghouat', 'École Normale Supérieure Taleb Abderrahmane de Laghouat (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Sud', 'Laghouat'),
('ENS Bou Saâda', 'École Normale Supérieure de Bou Saâda (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Est', 'M''sila'),
('ENS El Eulma', 'École Normale Supérieure d''El Eulma (Dépt. Sciences Naturelles, Sétif)', 'École Nationale Supérieure', 'Est', 'Sétif'),
('ENS Béchar', 'École Normale Supérieure de Béchar (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Sud', 'Béchar'),
('ENS Mostaganem', 'École Normale Supérieure de Mostaganem (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Ouest', 'Mostaganem'),
('ENS Skikda', 'École Normale Supérieure de Skikda (Dépt. Sciences Naturelles)', 'École Nationale Supérieure', 'Est', 'Skikda'),

('IPA', 'Institut Pasteur d''Algérie (Alger et annexes régionales)', 'Institut / Centre de Recherche', 'National', 'Alger'),
('INATAA', 'Institut de la Nutrition, de l''Alimentation et des Technologies Agro-Alimentaires (UFMC1, Constantine)', 'Institut / Centre de Recherche', 'Est', 'Constantine'),
('ISV Blida 1', 'Institut des Sciences Vétérinaires (USDB, Blida 1)', 'Institut / Centre de Recherche', 'Centre', 'Blida'),
('ISV Constantine 1', 'Institut des Sciences Vétérinaires (UFMC1, Constantine 1)', 'Institut / Centre de Recherche', 'Est', 'Constantine'),
('ISV Tiaret', 'Institut des Sciences Vétérinaires (Univ. Tiaret)', 'Institut / Centre de Recherche', 'Ouest', 'Tiaret'),
('ISV Batna 1', 'Institut des Sciences Vétérinaires (UB1, Batna 1)', 'Institut / Centre de Recherche', 'Est', 'Batna'),
('ISV El Tarf', 'Institut des Sciences Vétérinaires (Univ. El Tarf)', 'Institut / Centre de Recherche', 'Est', 'El Tarf'),
('ISA Chlef', 'Institut des Sciences Agronomiques (UHBC, Chlef)', 'Institut / Centre de Recherche', 'Ouest', 'Chlef'),
('ISA Sidi Bel Abbès', 'Institut des Sciences Agronomiques (UDL, Sidi Bel Abbès)', 'Institut / Centre de Recherche', 'Ouest', 'Sidi Bel Abbès'),
('ISA Batna 1', 'Institut des Sciences Agronomiques (UB1, Batna 1)', 'Institut / Centre de Recherche', 'Est', 'Batna'),
('ISA Béjaïa', 'Institut des Sciences Agronomiques (UAMB, Béjaïa)', 'Institut / Centre de Recherche', 'Est', 'Béjaïa'),
('ISTA Aïn Témouchent', 'Institut des Sciences et Techniques Appliquées (Univ. Aïn Témouchent)', 'Institut / Centre de Recherche', 'Ouest', 'Aïn Témouchent'),
('ISTA Ouargla', 'Institut des Sciences et Techniques Appliquées (UKMO, Ouargla)', 'Institut / Centre de Recherche', 'Sud', 'Ouargla'),
('INRAA', 'Institut National de la Recherche Agronomique d''Algérie (Alger et stations régionales)', 'Institut / Centre de Recherche', 'National', 'Alger'),
('CRBt', 'Centre de Recherche en Biotechnologie (Constantine)', 'Institut / Centre de Recherche', 'Est', 'Constantine'),
('INFSPM', 'Instituts Nationaux de Formation Supérieure Paramédicale (Spécialité : Laborantins de Santé Publique)', 'Institut / Centre de Recherche', 'National', null),
('INFEP', 'Institut National de la Formation et de l''Enseignement Professionnels (Contrôle de Qualité Agroalimentaire)', 'Institut / Centre de Recherche', 'National', null)
on conflict (name_fr) do nothing;
