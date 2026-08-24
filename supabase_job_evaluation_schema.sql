-- Job Evaluation approval workflow schema for Supabase/PostgreSQL.
-- Target roles in JWT app_metadata.role: HR_Analyst, JE_Committee_Member, HR_Head.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'je_evaluation_status') then
    create type public.je_evaluation_status as enum (
      'Draft',
      'Submitted',
      'Committee Reviewed',
      'Approved',
      'Rejected',
      'Recalibrated'
    );
  end if;
end $$;

create or replace function public.current_app_role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(auth.jwt() -> 'app_metadata' ->> 'role', ''),
    nullif(auth.jwt() -> 'user_metadata' ->> 'role', ''),
    'HR_Analyst'
  );
$$;

create table if not exists public.job_evaluations (
  id uuid primary key default gen_random_uuid(),
  evaluation_id text not null,
  version_number integer not null default 1 check (version_number >= 1),
  is_latest_version boolean not null default true,
  score_model_version text not null,
  job_title text not null,
  department text not null,
  jd_reference_text text,
  factor_scores jsonb not null default '{}'::jsonb,
  factor_rationales jsonb not null default '{}'::jsonb,
  total_score integer not null check (total_score between 120 and 1200),
  recommended_level text not null check (recommended_level in ('L1','L2','L3','L4','L5','L6','L7','L8')),
  final_approved_level text check (final_approved_level is null or final_approved_level in ('L1','L2','L3','L4','L5','L6','L7','L8')),
  current_status public.je_evaluation_status not null default 'Draft',
  created_by text not null default coalesce(auth.jwt() ->> 'email', auth.uid()::text),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_by text,
  submitted_at timestamptz,
  committee_reviewers jsonb not null default '[]'::jsonb,
  committee_reviewed_at timestamptz,
  committee_consensus_notes text,
  benchmark_notes text,
  approved_by text,
  decision_date timestamptz,
  decision_comments text,
  supersedes_id uuid references public.job_evaluations(id),
  constraint job_evaluations_business_version_unique unique (evaluation_id, version_number)
);

create index if not exists job_evaluations_business_key_idx
  on public.job_evaluations (evaluation_id, version_number desc);
create index if not exists job_evaluations_latest_idx
  on public.job_evaluations (is_latest_version) where is_latest_version;
create index if not exists job_evaluations_status_idx
  on public.job_evaluations (current_status);

create table if not exists public.job_evaluation_audit_logs (
  id uuid primary key default gen_random_uuid(),
  evaluation_record_id uuid not null references public.job_evaluations(id) on delete cascade,
  evaluation_id text not null,
  version_number integer not null,
  changed_at timestamptz not null default now(),
  changed_by text not null default coalesce(auth.jwt() ->> 'email', auth.uid()::text),
  from_status text,
  to_status text not null,
  comments text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists job_evaluation_audit_logs_record_idx
  on public.job_evaluation_audit_logs (evaluation_record_id, changed_at desc);

create or replace function public.touch_job_evaluation_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_touch_job_evaluations on public.job_evaluations;
create trigger trg_touch_job_evaluations
before update on public.job_evaluations
for each row execute function public.touch_job_evaluation_updated_at();

create or replace function public.validate_je_status_transition()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    return new;
  end if;

  if old.current_status = new.current_status then
    return new;
  end if;

  if old.current_status = 'Draft' and new.current_status in ('Submitted') then
    return new;
  elsif old.current_status = 'Submitted' and new.current_status in ('Committee Reviewed', 'Rejected') then
    return new;
  elsif old.current_status = 'Committee Reviewed' and new.current_status in ('Approved', 'Rejected') then
    return new;
  elsif old.current_status = 'Rejected' and new.current_status in ('Draft', 'Submitted') then
    return new;
  elsif old.current_status = 'Approved' and new.current_status in ('Recalibrated') then
    return new;
  end if;

  raise exception 'Invalid JE status transition from % to %', old.current_status, new.current_status;
end;
$$;

drop trigger if exists trg_validate_je_status_transition on public.job_evaluations;
create trigger trg_validate_je_status_transition
before update of current_status on public.job_evaluations
for each row execute function public.validate_je_status_transition();

create or replace function public.log_je_status_transition()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.job_evaluation_audit_logs (
      evaluation_record_id, evaluation_id, version_number, changed_by,
      from_status, to_status, comments, metadata
    ) values (
      new.id, new.evaluation_id, new.version_number, new.created_by,
      null, new.current_status::text, 'Evaluation record created',
      jsonb_build_object('score_model_version', new.score_model_version)
    );
    return new;
  end if;

  if old.current_status is distinct from new.current_status then
    insert into public.job_evaluation_audit_logs (
      evaluation_record_id, evaluation_id, version_number, changed_by,
      from_status, to_status, comments, metadata
    ) values (
      new.id, new.evaluation_id, new.version_number,
      coalesce(auth.jwt() ->> 'email', auth.uid()::text, new.updated_at::text),
      old.current_status::text, new.current_status::text,
      new.decision_comments,
      jsonb_build_object(
        'final_approved_level', new.final_approved_level,
        'committee_reviewers', new.committee_reviewers,
        'submitted_at', new.submitted_at,
        'committee_reviewed_at', new.committee_reviewed_at,
        'decision_date', new.decision_date
      )
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_je_insert on public.job_evaluations;
create trigger trg_log_je_insert
after insert on public.job_evaluations
for each row execute function public.log_je_status_transition();

drop trigger if exists trg_log_je_status_update on public.job_evaluations;
create trigger trg_log_je_status_update
after update of current_status on public.job_evaluations
for each row execute function public.log_je_status_transition();

alter table public.job_evaluations enable row level security;
alter table public.job_evaluation_audit_logs enable row level security;

drop policy if exists "JE users can read evaluations" on public.job_evaluations;
create policy "JE users can read evaluations"
on public.job_evaluations for select
using (public.current_app_role() in ('HR_Analyst', 'JE_Committee_Member', 'HR_Head'));

drop policy if exists "HR analysts create draft evaluations" on public.job_evaluations;
create policy "HR analysts create draft evaluations"
on public.job_evaluations for insert
with check (
  public.current_app_role() = 'HR_Analyst'
  and current_status = 'Draft'
);

drop policy if exists "HR analysts edit draft rejected submitted data" on public.job_evaluations;
create policy "HR analysts edit draft rejected submitted data"
on public.job_evaluations for update
using (
  public.current_app_role() = 'HR_Analyst'
  and current_status in ('Draft', 'Rejected')
)
with check (
  public.current_app_role() = 'HR_Analyst'
  and current_status in ('Draft', 'Submitted')
);

drop policy if exists "Committee reviews submitted evaluations" on public.job_evaluations;
create policy "Committee reviews submitted evaluations"
on public.job_evaluations for update
using (
  public.current_app_role() = 'JE_Committee_Member'
  and current_status = 'Submitted'
)
with check (
  public.current_app_role() = 'JE_Committee_Member'
  and current_status in ('Committee Reviewed', 'Rejected')
);

drop policy if exists "HR head approves committee reviewed evaluations" on public.job_evaluations;
create policy "HR head approves committee reviewed evaluations"
on public.job_evaluations for update
using (
  public.current_app_role() = 'HR_Head'
  and current_status in ('Committee Reviewed', 'Approved')
)
with check (
  public.current_app_role() = 'HR_Head'
  and current_status in ('Approved', 'Rejected', 'Recalibrated')
);

drop policy if exists "JE users can read audit logs" on public.job_evaluation_audit_logs;
create policy "JE users can read audit logs"
on public.job_evaluation_audit_logs for select
using (public.current_app_role() in ('HR_Analyst', 'JE_Committee_Member', 'HR_Head'));

drop policy if exists "System inserts audit logs through triggers" on public.job_evaluation_audit_logs;
create policy "System inserts audit logs through triggers"
on public.job_evaluation_audit_logs for insert
with check (public.current_app_role() in ('HR_Analyst', 'JE_Committee_Member', 'HR_Head'));
