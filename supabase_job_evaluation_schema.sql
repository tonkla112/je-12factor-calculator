-- Job Evaluation approval workflow schema for Supabase/PostgreSQL.
-- Target JE roles: HR_Analyst, JE_Committee_Member, HR_Head.
-- Roles can be assigned in public.je_user_roles from the Admin/User Management screen.
-- JWT app_metadata.role, app_metadata.je_role, and app_metadata.je_roles remain supported
-- for initial bootstrap access.

create extension if not exists pgcrypto;

create table if not exists public.je_user_roles (
  id uuid primary key default gen_random_uuid(),
  email text not null check (position('@' in email) > 1),
  email_normalized text generated always as (lower(btrim(email))) stored,
  full_name text,
  department text,
  roles text[] not null default '{}'::text[],
  is_active boolean not null default true,
  invited_by text not null default coalesce(auth.jwt() ->> 'email', auth.uid()::text),
  invited_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now(),
  constraint je_user_roles_email_unique unique (email_normalized),
  constraint je_user_roles_allowed_roles check (
    roles <@ array['HR_Analyst','JE_Committee_Member','HR_Head']::text[]
  ),
  constraint je_user_roles_needs_role check (cardinality(roles) >= 1)
);

create index if not exists je_user_roles_active_idx
  on public.je_user_roles (is_active, email_normalized);

create table if not exists public.je_user_role_audit_logs (
  id uuid primary key default gen_random_uuid(),
  role_record_id uuid references public.je_user_roles(id) on delete set null,
  target_email text not null,
  changed_at timestamptz not null default now(),
  changed_by text not null default coalesce(auth.jwt() ->> 'email', auth.uid()::text),
  action text not null check (action in ('Created','Updated')),
  from_roles text[],
  to_roles text[],
  from_active boolean,
  to_active boolean,
  comments text,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists je_user_role_audit_logs_target_idx
  on public.je_user_role_audit_logs (target_email, changed_at desc);

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
    nullif(auth.jwt() -> 'app_metadata' ->> 'je_role', '')
  );
$$;

create or replace function public.has_je_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with claims as (
    select
      coalesce(auth.jwt() -> 'app_metadata', '{}'::jsonb) as metadata,
      lower(nullif(auth.jwt() ->> 'email', '')) as email
  )
  select coalesce(
    (metadata ->> 'role') = required_role
    or (metadata ->> 'je_role') = required_role
    or (case when jsonb_typeof(metadata -> 'je_roles') = 'array'
        then (metadata -> 'je_roles') ? required_role
        else false
      end)
    or exists (
      select 1
      from public.je_user_roles jur
      where jur.email_normalized = claims.email
        and jur.is_active
        and required_role = any(jur.roles)
    ),
    false
  )
  from claims;
$$;

create or replace function public.get_je_notification_recipients(role_names text[])
returns table(email text, full_name text, roles text[])
language sql
stable
security definer
set search_path = public
as $$
  select jur.email_normalized as email, jur.full_name, jur.roles
  from public.je_user_roles jur
  where jur.is_active
    and jur.roles && role_names
    and (
      public.has_je_role('HR_Analyst')
      or public.has_je_role('JE_Committee_Member')
      or public.has_je_role('HR_Head')
    )
  order by jur.email_normalized;
$$;

create or replace function public.touch_je_user_roles_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  new.updated_by = coalesce(auth.jwt() ->> 'email', auth.uid()::text, new.updated_by);
  return new;
end;
$$;

drop trigger if exists trg_touch_je_user_roles on public.je_user_roles;
create trigger trg_touch_je_user_roles
before update on public.je_user_roles
for each row execute function public.touch_je_user_roles_updated_at();

create or replace function public.log_je_user_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.je_user_role_audit_logs (
      role_record_id, target_email, changed_by, action, to_roles, to_active, comments, metadata
    ) values (
      new.id, new.email_normalized,
      coalesce(auth.jwt() ->> 'email', auth.uid()::text, new.invited_by),
      'Created', new.roles, new.is_active, 'JE user access created',
      jsonb_build_object('full_name', new.full_name, 'department', new.department)
    );
    return new;
  end if;

  if old.roles is distinct from new.roles or old.is_active is distinct from new.is_active then
    insert into public.je_user_role_audit_logs (
      role_record_id, target_email, changed_by, action,
      from_roles, to_roles, from_active, to_active, comments, metadata
    ) values (
      new.id, new.email_normalized,
      coalesce(auth.jwt() ->> 'email', auth.uid()::text, new.updated_by),
      'Updated', old.roles, new.roles, old.is_active, new.is_active,
      'JE user access updated',
      jsonb_build_object('full_name', new.full_name, 'department', new.department)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_je_user_role_insert on public.je_user_roles;
create trigger trg_log_je_user_role_insert
after insert on public.je_user_roles
for each row execute function public.log_je_user_role_change();

drop trigger if exists trg_log_je_user_role_update on public.je_user_roles;
create trigger trg_log_je_user_role_update
after update on public.je_user_roles
for each row execute function public.log_je_user_role_change();

create table if not exists public.job_evaluations (
  id uuid primary key default gen_random_uuid(),
  evaluation_id text not null,
  version_number integer not null default 1 check (version_number >= 1),
  is_latest_version boolean not null default true,
  score_model_version text not null,
  job_title text not null,
  department text not null,
  jd_reference_text text,
  current_salary numeric,
  salary_range_check jsonb,
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

alter table public.job_evaluations
  add column if not exists current_salary numeric;

alter table public.job_evaluations
  add column if not exists salary_range_check jsonb;

create index if not exists job_evaluations_salary_check_status_idx
  on public.job_evaluations ((salary_range_check ->> 'status'))
  where salary_range_check is not null;

create or replace view public.je_compensation_alert_register
with (security_invoker = true)
as
select
  je.id,
  je.evaluation_id,
  je.version_number,
  je.is_latest_version,
  je.job_title,
  je.department,
  je.current_status,
  coalesce(je.final_approved_level, je.recommended_level) as je_level,
  je.total_score,
  je.current_salary,
  je.salary_range_check,
  je.salary_range_check ->> 'status' as alert_status,
  (je.salary_range_check ->> 'message') as alert_message,
  je.updated_at,
  je.created_by,
  case
    when je.current_status in ('Draft', 'Rejected') then 'HR Analyst'
    when je.current_status = 'Submitted' then 'JE Committee'
    when je.current_status = 'Committee Reviewed' then 'HR Head'
    when je.current_status = 'Approved' then 'Completed'
    when je.current_status = 'Recalibrated' then 'Archived'
    else 'HR Analyst'
  end as pending_with
from public.job_evaluations je
where je.salary_range_check is not null
  and je.current_salary is not null
  and je.salary_range_check ->> 'status' in ('warn', 'error');

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

create table if not exists public.je_notification_logs (
  id uuid primary key default gen_random_uuid(),
  evaluation_record_id uuid references public.job_evaluations(id) on delete set null,
  evaluation_id text not null,
  version_number integer not null,
  from_status text,
  to_status text not null,
  to_emails text[] not null default '{}'::text[],
  cc_emails text[] not null default '{}'::text[],
  subject text not null,
  body text not null,
  delivery_status text not null default 'Queued' check (delivery_status in ('Queued','Sent','Skipped','Failed')),
  triggered_by text not null default coalesce(auth.jwt() ->> 'email', auth.uid()::text),
  triggered_at timestamptz not null default now(),
  provider text,
  provider_response jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists je_notification_logs_eval_idx
  on public.je_notification_logs (evaluation_record_id, triggered_at desc);

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
        'current_salary', new.current_salary,
        'salary_range_check', new.salary_range_check,
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
alter table public.je_user_roles enable row level security;
alter table public.je_user_role_audit_logs enable row level security;
alter table public.je_notification_logs enable row level security;

drop policy if exists "JE users can read their own role and HR head can read all" on public.je_user_roles;
create policy "JE users can read their own role and HR head can read all"
on public.je_user_roles for select
to authenticated
using (
  email_normalized = lower(auth.jwt() ->> 'email')
  or public.has_je_role('HR_Head')
);

drop policy if exists "HR head creates JE users" on public.je_user_roles;
create policy "HR head creates JE users"
on public.je_user_roles for insert
to authenticated
with check (public.has_je_role('HR_Head'));

drop policy if exists "HR head updates JE users" on public.je_user_roles;
create policy "HR head updates JE users"
on public.je_user_roles for update
to authenticated
using (public.has_je_role('HR_Head'))
with check (public.has_je_role('HR_Head'));

drop policy if exists "HR head reads JE role audit logs" on public.je_user_role_audit_logs;
create policy "HR head reads JE role audit logs"
on public.je_user_role_audit_logs for select
to authenticated
using (public.has_je_role('HR_Head'));

drop policy if exists "JE users can read notification logs" on public.je_notification_logs;
create policy "JE users can read notification logs"
on public.je_notification_logs for select
to authenticated
using (
  public.has_je_role('HR_Analyst')
  or public.has_je_role('JE_Committee_Member')
  or public.has_je_role('HR_Head')
);

drop policy if exists "JE users can queue notification logs" on public.je_notification_logs;
create policy "JE users can queue notification logs"
on public.je_notification_logs for insert
to authenticated
with check (
  public.has_je_role('HR_Analyst')
  or public.has_je_role('JE_Committee_Member')
  or public.has_je_role('HR_Head')
);

drop policy if exists "JE users can read evaluations" on public.job_evaluations;
create policy "JE users can read evaluations"
on public.job_evaluations for select
to authenticated
using (
  public.has_je_role('HR_Analyst')
  or public.has_je_role('JE_Committee_Member')
  or public.has_je_role('HR_Head')
);

drop policy if exists "HR analysts create draft evaluations" on public.job_evaluations;
create policy "HR analysts create draft evaluations"
on public.job_evaluations for insert
to authenticated
with check (
  public.has_je_role('HR_Analyst')
  and current_status = 'Draft'
);

drop policy if exists "HR analysts edit draft rejected submitted data" on public.job_evaluations;
create policy "HR analysts edit draft rejected submitted data"
on public.job_evaluations for update
to authenticated
using (
  public.has_je_role('HR_Analyst')
  and current_status in ('Draft', 'Rejected')
)
with check (
  public.has_je_role('HR_Analyst')
  and current_status in ('Draft', 'Submitted')
);

drop policy if exists "Committee reviews submitted evaluations" on public.job_evaluations;
create policy "Committee reviews submitted evaluations"
on public.job_evaluations for update
to authenticated
using (
  public.has_je_role('JE_Committee_Member')
  and current_status = 'Submitted'
)
with check (
  public.has_je_role('JE_Committee_Member')
  and current_status in ('Committee Reviewed', 'Rejected')
);

drop policy if exists "HR head approves committee reviewed evaluations" on public.job_evaluations;
create policy "HR head approves committee reviewed evaluations"
on public.job_evaluations for update
to authenticated
using (
  public.has_je_role('HR_Head')
  and current_status in ('Committee Reviewed', 'Approved')
)
with check (
  public.has_je_role('HR_Head')
  and current_status in ('Approved', 'Rejected', 'Recalibrated')
);

drop policy if exists "JE users can read audit logs" on public.job_evaluation_audit_logs;
create policy "JE users can read audit logs"
on public.job_evaluation_audit_logs for select
to authenticated
using (
  public.has_je_role('HR_Analyst')
  or public.has_je_role('JE_Committee_Member')
  or public.has_je_role('HR_Head')
);

drop policy if exists "System inserts audit logs through triggers" on public.job_evaluation_audit_logs;
create policy "System inserts audit logs through triggers"
on public.job_evaluation_audit_logs for insert
to authenticated
with check (
  public.has_je_role('HR_Analyst')
  or public.has_je_role('JE_Committee_Member')
  or public.has_je_role('HR_Head')
);

grant usage on schema public to authenticated;
grant select, insert, update on public.je_user_roles to authenticated;
grant select on public.je_user_role_audit_logs to authenticated;
grant select, insert on public.je_notification_logs to authenticated;
grant execute on function public.get_je_notification_recipients(text[]) to authenticated;
grant select, insert, update on public.job_evaluations to authenticated;
grant select, insert on public.job_evaluation_audit_logs to authenticated;
grant select on public.je_compensation_alert_register to authenticated;
