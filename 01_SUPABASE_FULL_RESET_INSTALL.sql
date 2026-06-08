-- 거북팀 훈련 입력 웹앱 전체 새 설치 SQL
-- Supabase > SQL Editor > New query 에 이 파일 전체를 붙여넣고 Run 하세요.
-- 주의: 이 파일은 기존 테이블을 삭제하고 새로 만듭니다. 처음부터 다시 시작할 때만 사용하세요.
-- 최초 관리자 로그인: 관리자 / 1234

-- ===== 기존 앱 데이터 초기화 =====
drop table if exists run_logs cascade;
drop table if exists member_profiles cascade;
drop table if exists training_plan cascade;
drop table if exists app_sessions cascade;
drop table if exists app_members cascade;

drop function if exists app_hash_password(text, text) cascade;
drop function if exists require_member(uuid) cascade;
drop function if exists require_admin(uuid) cascade;
drop function if exists login_member(text, text) cascade;
drop function if exists register_member(text, text) cascade;
drop function if exists logout_member(uuid) cascade;
drop function if exists list_plan(uuid) cascade;
drop function if exists upsert_log(uuid, uuid, date, numeric, text, text) cascade;
drop function if exists delete_my_log(uuid, uuid) cascade;
drop function if exists get_my_logs(uuid) cascade;
drop function if exists get_my_summary(uuid) cascade;
drop function if exists get_my_profile(uuid) cascade;
drop function if exists upsert_my_profile(uuid, jsonb) cascade;
drop function if exists change_my_password(uuid, text, text) cascade;
drop function if exists admin_create_member(uuid, text, text, text) cascade;
drop function if exists admin_list_members(uuid) cascade;
drop function if exists admin_summary(uuid) cascade;
drop function if exists admin_all_logs(uuid) cascade;
drop function if exists admin_profiles(uuid) cascade;

-- pgcrypto digest를 쓰지 않습니다. Supabase 프로젝트별 함수 경로 문제를 피하려고 기본 md5()만 사용합니다.
create or replace function app_hash_password(p_name text, p_password text)
returns text
language sql
immutable
as $$
  select md5(trim(coalesce(p_name, '')) || ':' || trim(coalesce(p_password, '')) || ':gobuk-run-v2');
$$;

-- ===== 테이블 =====
create table app_members (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  password_hash text not null,
  role text not null default 'runner' check (role in ('runner', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app_sessions (
  token uuid primary key default gen_random_uuid(),
  member_id uuid not null references app_members(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);

create table training_plan (
  id uuid primary key default gen_random_uuid(),
  week_no int not null,
  phase text,
  plan_date date not null unique,
  day_name text not null,
  division text,
  workout_type text,
  planned_km numeric(6,1) not null default 0,
  workout text,
  pace_guide text,
  coach_note text,
  created_at timestamptz not null default now()
);

create table run_logs (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app_members(id) on delete cascade,
  plan_id uuid references training_plan(id) on delete set null,
  log_date date not null,
  actual_km numeric(6,2) not null default 0 check (actual_km >= 0),
  status text not null default 'done' check (status in ('done', 'partial', 'rest', 'skipped')),
  memo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(member_id, log_date)
);

create table member_profiles (
  member_id uuid primary key references app_members(id) on delete cascade,
  profile_no int,
  nickname text,
  gender text,
  birth_year int,
  goal_record text,
  vo2max numeric(5,1),
  lt_pace text,
  lt_hr int,
  expected_10k text,
  expected_half text,
  expected_full text,
  weekly_available_count int,
  personal_jog_days text,
  team_training_days text,
  pain_yn text,
  current_pain text,
  longrun_weakness text,
  risk_note text,
  help_request text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index run_logs_member_date_idx on run_logs(member_id, log_date);
create index training_plan_date_idx on training_plan(plan_date);
create index member_profiles_no_idx on member_profiles(profile_no);

alter table app_members enable row level security;
alter table app_sessions enable row level security;
alter table training_plan enable row level security;
alter table run_logs enable row level security;
alter table member_profiles enable row level security;

-- 테이블 직접 접근은 막고 RPC 함수로만 접근합니다.
revoke all on app_members from anon, authenticated;
revoke all on app_sessions from anon, authenticated;
revoke all on training_plan from anon, authenticated;
revoke all on run_logs from anon, authenticated;
revoke all on member_profiles from anon, authenticated;

-- ===== 권한 확인 함수 =====
create or replace function require_member(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select s.member_id into v_member_id
  from app_sessions s
  where s.token = p_token and s.expires_at > now();

  if v_member_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  return v_member_id;
end;
$$;

create or replace function require_admin(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_role text;
begin
  v_member_id := require_member(p_token);
  select role into v_role from app_members where id = v_member_id;

  if v_role <> 'admin' then
    raise exception '관리자 권한이 필요합니다.';
  end if;

  return v_member_id;
end;
$$;

-- ===== 로그인/가입 =====
create or replace function login_member(p_name text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member app_members%rowtype;
  v_token uuid := gen_random_uuid();
begin
  select * into v_member
  from app_members
  where name = trim(p_name)
    and password_hash = app_hash_password(trim(p_name), trim(p_password));

  if not found then
    raise exception '이름 또는 비밀번호가 맞지 않습니다.';
  end if;

  insert into app_sessions(token, member_id, expires_at)
  values (v_token, v_member.id, now() + interval '30 days');

  return jsonb_build_object(
    'token', v_token,
    'member', jsonb_build_object('id', v_member.id, 'name', v_member.name, 'role', v_member.role)
  );
end;
$$;

create or replace function register_member(p_name text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member app_members%rowtype;
  v_token uuid := gen_random_uuid();
  v_name text := trim(coalesce(p_name, ''));
  v_password text := trim(coalesce(p_password, ''));
begin
  if length(v_name) < 2 then
    raise exception '이름은 2글자 이상 입력해주세요.';
  end if;

  if length(v_name) > 30 then
    raise exception '이름은 30글자 이내로 입력해주세요.';
  end if;

  if length(v_password) < 4 then
    raise exception '비밀번호는 4글자 이상 입력해주세요.';
  end if;

  if exists (select 1 from app_members where name = v_name) then
    raise exception '이미 사용 중인 이름입니다. 관리자에게 문의하거나 다른 이름으로 가입해주세요.';
  end if;

  insert into app_members(name, password_hash, role)
  values (v_name, app_hash_password(v_name, v_password), 'runner')
  returning * into v_member;

  insert into app_sessions(token, member_id, expires_at)
  values (v_token, v_member.id, now() + interval '30 days');

  return jsonb_build_object(
    'token', v_token,
    'member', jsonb_build_object('id', v_member.id, 'name', v_member.name, 'role', v_member.role)
  );
end;
$$;

create or replace function logout_member(p_token uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from app_sessions where token = p_token;
  return true;
end;
$$;

-- ===== 훈련표/기록 =====
create or replace function list_plan(p_token uuid)
returns table (
  id uuid,
  week_no int,
  phase text,
  plan_date date,
  day_name text,
  division text,
  workout_type text,
  planned_km numeric,
  workout text,
  pace_guide text,
  coach_note text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_member(p_token);
  return query
  select p.id, p.week_no, p.phase, p.plan_date, p.day_name, p.division, p.workout_type,
         p.planned_km, p.workout, p.pace_guide, p.coach_note
  from training_plan p
  order by p.plan_date;
end;
$$;

create or replace function upsert_log(
  p_token uuid,
  p_plan_id uuid,
  p_log_date date,
  p_actual_km numeric,
  p_status text,
  p_memo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_log run_logs%rowtype;
  v_status text := coalesce(nullif(p_status, ''), 'done');
begin
  v_member_id := require_member(p_token);

  if v_status not in ('done', 'partial', 'rest', 'skipped') then
    raise exception '실행상태가 올바르지 않습니다.';
  end if;

  insert into run_logs(member_id, plan_id, log_date, actual_km, status, memo, updated_at)
  values (v_member_id, p_plan_id, p_log_date, coalesce(p_actual_km, 0), v_status, nullif(p_memo, ''), now())
  on conflict (member_id, log_date)
  do update set
    plan_id = excluded.plan_id,
    actual_km = excluded.actual_km,
    status = excluded.status,
    memo = excluded.memo,
    updated_at = now()
  returning * into v_log;

  return to_jsonb(v_log);
end;
$$;

create or replace function delete_my_log(p_token uuid, p_log_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_count int;
begin
  v_member_id := require_member(p_token);

  delete from run_logs
  where id = p_log_id and member_id = v_member_id;

  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception '삭제할 기록이 없습니다.';
  end if;

  return true;
end;
$$;

create or replace function get_my_logs(p_token uuid)
returns table (
  id uuid,
  plan_id uuid,
  log_date date,
  actual_km numeric,
  status text,
  memo text,
  planned_km numeric,
  workout_type text,
  workout text,
  pace_guide text,
  coach_note text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  v_member_id := require_member(p_token);

  return query
  select l.id, l.plan_id, l.log_date, l.actual_km, l.status, l.memo,
         p.planned_km, p.workout_type, p.workout, p.pace_guide, p.coach_note
  from run_logs l
  left join training_plan p on p.id = l.plan_id
  where l.member_id = v_member_id
  order by l.log_date desc, l.created_at desc;
end;
$$;

create or replace function get_my_summary(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_total_km numeric;
  v_actual_until numeric;
  v_planned_until numeric;
  v_planned_count int;
  v_done_count int;
  v_last_log_date date;
begin
  v_member_id := require_member(p_token);

  select coalesce(sum(actual_km), 0), max(log_date)
  into v_total_km, v_last_log_date
  from run_logs
  where member_id = v_member_id;

  select coalesce(sum(actual_km), 0)
  into v_actual_until
  from run_logs
  where member_id = v_member_id and log_date <= current_date;

  select coalesce(sum(planned_km), 0), count(*)
  into v_planned_until, v_planned_count
  from training_plan
  where plan_date <= current_date and planned_km > 0;

  select count(distinct l.log_date)
  into v_done_count
  from run_logs l
  join training_plan p on p.plan_date = l.log_date and p.planned_km > 0
  where l.member_id = v_member_id
    and l.log_date <= current_date
    and l.status in ('done', 'partial');

  return jsonb_build_object(
    'total_km', v_total_km,
    'actual_km_until_today', v_actual_until,
    'planned_km_until_today', v_planned_until,
    'distance_rate_pct', case when v_planned_until > 0 then round((v_actual_until / v_planned_until) * 100, 1) else 0 end,
    'planned_count', v_planned_count,
    'done_count', coalesce(v_done_count, 0),
    'execution_rate_pct', case when v_planned_count > 0 then round((coalesce(v_done_count, 0)::numeric / v_planned_count) * 100, 1) else 0 end,
    'last_log_date', v_last_log_date
  );
end;
$$;

-- ===== 내 정보/비밀번호 =====
create or replace function get_my_profile(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_profile jsonb;
begin
  v_member_id := require_member(p_token);

  select to_jsonb(mp) - 'member_id' - 'created_at' - 'updated_at'
  into v_profile
  from member_profiles mp
  where mp.member_id = v_member_id;

  return coalesce(v_profile, '{}'::jsonb);
end;
$$;

create or replace function upsert_my_profile(p_token uuid, p_profile jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  v_member_id := require_member(p_token);

  insert into member_profiles(
    member_id, profile_no, nickname, gender, birth_year, goal_record, vo2max, lt_pace, lt_hr,
    expected_10k, expected_half, expected_full, weekly_available_count,
    personal_jog_days, team_training_days, pain_yn, current_pain, longrun_weakness, risk_note, help_request, updated_at
  ) values (
    v_member_id,
    nullif(p_profile->>'profile_no', '')::int,
    nullif(p_profile->>'nickname', ''),
    nullif(p_profile->>'gender', ''),
    nullif(p_profile->>'birth_year', '')::int,
    nullif(p_profile->>'goal_record', ''),
    nullif(p_profile->>'vo2max', '')::numeric,
    nullif(p_profile->>'lt_pace', ''),
    nullif(p_profile->>'lt_hr', '')::int,
    nullif(p_profile->>'expected_10k', ''),
    nullif(p_profile->>'expected_half', ''),
    nullif(p_profile->>'expected_full', ''),
    nullif(p_profile->>'weekly_available_count', '')::int,
    nullif(p_profile->>'personal_jog_days', ''),
    nullif(p_profile->>'team_training_days', ''),
    nullif(p_profile->>'pain_yn', ''),
    nullif(p_profile->>'current_pain', ''),
    nullif(p_profile->>'longrun_weakness', ''),
    nullif(p_profile->>'risk_note', ''),
    nullif(p_profile->>'help_request', ''),
    now()
  )
  on conflict (member_id) do update set
    profile_no = excluded.profile_no,
    nickname = excluded.nickname,
    gender = excluded.gender,
    birth_year = excluded.birth_year,
    goal_record = excluded.goal_record,
    vo2max = excluded.vo2max,
    lt_pace = excluded.lt_pace,
    lt_hr = excluded.lt_hr,
    expected_10k = excluded.expected_10k,
    expected_half = excluded.expected_half,
    expected_full = excluded.expected_full,
    weekly_available_count = excluded.weekly_available_count,
    personal_jog_days = excluded.personal_jog_days,
    team_training_days = excluded.team_training_days,
    pain_yn = excluded.pain_yn,
    current_pain = excluded.current_pain,
    longrun_weakness = excluded.longrun_weakness,
    risk_note = excluded.risk_note,
    help_request = excluded.help_request,
    updated_at = now();

  return get_my_profile(p_token);
end;
$$;

create or replace function change_my_password(p_token uuid, p_current_password text, p_new_password text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_member app_members%rowtype;
  v_new text := trim(coalesce(p_new_password, ''));
begin
  v_member_id := require_member(p_token);
  select * into v_member from app_members where id = v_member_id;

  if v_member.password_hash <> app_hash_password(v_member.name, trim(coalesce(p_current_password, ''))) then
    raise exception '현재 비밀번호가 맞지 않습니다.';
  end if;

  if length(v_new) < 4 then
    raise exception '새 비밀번호는 4글자 이상 입력해주세요.';
  end if;

  update app_members
  set password_hash = app_hash_password(v_member.name, v_new), updated_at = now()
  where id = v_member_id;

  return true;
end;
$$;

-- ===== 관리자 =====
create or replace function admin_create_member(p_token uuid, p_name text, p_password text, p_role text default 'runner')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_password text := trim(coalesce(p_password, ''));
  v_role text := coalesce(nullif(p_role, ''), 'runner');
  v_member app_members%rowtype;
begin
  perform require_admin(p_token);

  if v_role not in ('runner', 'admin') then
    raise exception '권한 값이 올바르지 않습니다.';
  end if;

  if length(v_name) < 2 then
    raise exception '이름은 2글자 이상 입력해주세요.';
  end if;

  if length(v_password) < 4 then
    raise exception '비밀번호는 4글자 이상 입력해주세요.';
  end if;

  insert into app_members(name, password_hash, role)
  values (v_name, app_hash_password(v_name, v_password), v_role)
  returning * into v_member;

  return to_jsonb(v_member) - 'password_hash';
end;
$$;

create or replace function admin_list_members(p_token uuid)
returns table (id uuid, name text, role text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_admin(p_token);
  return query select m.id, m.name, m.role, m.created_at from app_members m order by m.created_at;
end;
$$;

create or replace function admin_summary(p_token uuid)
returns table (
  member_id uuid,
  name text,
  role text,
  total_km numeric,
  actual_km_until_today numeric,
  planned_km_until_today numeric,
  distance_rate_pct numeric,
  planned_count int,
  done_count int,
  execution_rate_pct numeric,
  last_log_date date
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_admin(p_token);

  return query
  with plan_base as (
    select coalesce(sum(planned_km),0)::numeric as planned_km_until_today,
           count(*)::int as planned_count
    from training_plan
    where plan_date <= current_date and planned_km > 0
  ), member_calc as (
    select m.id as member_id,
           coalesce(sum(l.actual_km),0)::numeric as total_km,
           coalesce(sum(l.actual_km) filter (where l.log_date <= current_date),0)::numeric as actual_km_until_today,
           count(distinct l.log_date) filter (
             where l.log_date <= current_date and l.status in ('done','partial')
               and exists (select 1 from training_plan p where p.plan_date = l.log_date and p.planned_km > 0)
           )::int as done_count,
           max(l.log_date)::date as last_log_date
    from app_members m
    left join run_logs l on l.member_id = m.id
    group by m.id
  )
  select m.id, m.name, m.role,
         mc.total_km,
         mc.actual_km_until_today,
         pb.planned_km_until_today,
         case when pb.planned_km_until_today > 0 then round((mc.actual_km_until_today / pb.planned_km_until_today) * 100, 1) else 0 end as distance_rate_pct,
         pb.planned_count,
         mc.done_count,
         case when pb.planned_count > 0 then round((mc.done_count::numeric / pb.planned_count) * 100, 1) else 0 end as execution_rate_pct,
         mc.last_log_date
  from app_members m
  join member_calc mc on mc.member_id = m.id
  cross join plan_base pb
  order by m.created_at;
end;
$$;

create or replace function admin_all_logs(p_token uuid)
returns table (
  log_id uuid,
  member_id uuid,
  member_name text,
  log_date date,
  actual_km numeric,
  status text,
  status_label text,
  memo text,
  workout_type text,
  planned_km numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_admin(p_token);

  return query
  select l.id, m.id, m.name, l.log_date, l.actual_km, l.status,
         case l.status when 'done' then '완료' when 'partial' then '일부 완료' when 'rest' then '휴식' when 'skipped' then '미실시' else l.status end,
         l.memo, p.workout_type, p.planned_km
  from run_logs l
  join app_members m on m.id = l.member_id
  left join training_plan p on p.id = l.plan_id
  order by l.log_date desc, m.name;
end;
$$;

create or replace function admin_profiles(p_token uuid)
returns table (
  member_id uuid,
  name text,
  role text,
  profile_no int,
  nickname text,
  gender text,
  birth_year int,
  goal_record text,
  vo2max numeric,
  lt_pace text,
  lt_hr int,
  expected_10k text,
  expected_half text,
  expected_full text,
  weekly_available_count int,
  personal_jog_days text,
  team_training_days text,
  pain_yn text,
  current_pain text,
  longrun_weakness text,
  risk_note text,
  help_request text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_admin(p_token);

  return query
  select m.id, m.name, m.role,
         p.profile_no, p.nickname, p.gender, p.birth_year, p.goal_record, p.vo2max, p.lt_pace, p.lt_hr,
         p.expected_10k, p.expected_half, p.expected_full, p.weekly_available_count,
         p.personal_jog_days, p.team_training_days, p.pain_yn, p.current_pain,
         p.longrun_weakness, p.risk_note, p.help_request, p.updated_at
  from app_members m
  left join member_profiles p on p.member_id = m.id
  order by coalesce(p.profile_no, 9999), m.created_at;
end;
$$;

-- RPC 함수 실행 권한
grant execute on all functions in schema public to anon, authenticated;

-- ===== 초기 관리자 =====
insert into app_members(name, password_hash, role)
values ('관리자', app_hash_password('관리자', '1234'), 'admin');

-- ===== 훈련표 시드 =====
insert into training_plan(week_no, phase, plan_date, day_name, division, workout_type, planned_km, workout, pace_guide, coach_note)
select week_no, phase, plan_date, day_name, division, workout_type, planned_km, workout, pace_guide, coach_note
from jsonb_to_recordset($seed$
[
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-01",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-02",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m × 6, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 기록보다 자세.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-03",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-04",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-05",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 1,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-06",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-07",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 13.0,
    "workout": "다함께 5km + 1시간 Easy Run. 전체 RPE 3~4, 6'50~7'40/km 범위. 친목+유산소 기반, 초반 과속 금지.",
    "pace_guide": "Easy/LSD 기준",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-08",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-09",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m × 6, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 기록보다 자세.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-10",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-11",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-12",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 2,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-13",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-14",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-15",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-16",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 7.5,
    "workout": "워밍업 2km + 정발산 언덕 4회, 내려오며 충분 회복 + 쿨다운 1.5~2km. 오르막은 10K 노력도, 내려올 때 완전 회복.",
    "pace_guide": "언덕 RPE 7, 내려오며 완전 회복",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-17",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-18",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 8.0,
    "workout": "워밍업 2km + MP 지속주 5km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-19",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 3,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-20",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-21",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 8.0,
    "workout": "북한산 단체 산행. 러닝 대체 유산소 3~4시간으로 보고 주간 km는 8km 환산. 하산 후 종아리·둔근 스트레칭.",
    "pace_guide": "RPE 4~6, 페이스 집착 금지",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-22",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-23",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 800m × 3, 400m 걷기/조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 마지막까지 자세 유지.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-24",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-25",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "총 7km 빌드업. 7'20/km 안팎에서 시작해 마지막 1~2km만 6'10~6'20/km. 급가속 금지.",
    "pace_guide": "빌드업 마지막 6'10~6'20/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-26",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 4,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-27",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-28",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-29",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-06-30",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 40분 + 100m 스트라이드 3회. Easy 7'20~8'10/km, 스트라이드는 전력질주가 아니라 다리 리듬 확인.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-01",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-02",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 9.0,
    "workout": "워밍업 2km + MP 지속주 6km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-03",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 5,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-04",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-05",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-06",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-07",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m × 6, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 기록보다 자세.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-08",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-09",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-10",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 6,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-11",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-12",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-13",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-14",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 7.5,
    "workout": "워밍업 2km + 정발산 언덕 5회, 내려오며 충분 회복 + 쿨다운 1.5~2km. 오르막은 10K 노력도, 내려올 때 완전 회복.",
    "pace_guide": "언덕 RPE 7, 내려오며 완전 회복",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-15",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-16",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 8.0,
    "workout": "총 8km 빌드업. 7'20/km 안팎에서 시작해 마지막 1~2km만 6'10~6'20/km. 급가속 금지.",
    "pace_guide": "빌드업 마지막 6'10~6'20/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-17",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 7,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-18",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-19",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-20",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-21",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 1K × 3, 400m 조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 두 번째 이후 페이스 무너지면 종료.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-22",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-23",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 10.0,
    "workout": "워밍업 2km + MP 지속주 7km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-24",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 8,
    "phase": "1단계 기초체력·유산소 기반",
    "plan_date": "2026-07-25",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-26",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-27",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-28",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 800m × 4, 400m 조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 더우면 3회로 감량.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-29",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-30",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-07-31",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 9,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-01",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-02",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-03",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-04",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m × 6, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 기록보다 자세.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-05",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-06",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 11.0,
    "workout": "워밍업 2km + MP 지속주 8km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-07",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 10,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-08",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-09",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 16.0,
    "workout": "남산 전지훈련. 언덕 지속주 성격. 평지 페이스로 판단하지 말고 RPE 5~6, 보폭 짧게 안정적으로.",
    "pace_guide": "RPE 4~6, 페이스 집착 금지",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-10",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-11",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 7.5,
    "workout": "워밍업 2km + 정발산 언덕 5회, 내려오며 충분 회복 + 쿨다운 1.5~2km. 오르막은 10K 노력도, 내려올 때 완전 회복.",
    "pace_guide": "언덕 RPE 7, 내려오며 완전 회복",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-12",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-13",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 8.0,
    "workout": "총 8km 빌드업. 7'20/km 안팎에서 시작해 마지막 1~2km만 6'10~6'20/km. 급가속 금지.",
    "pace_guide": "빌드업 마지막 6'10~6'20/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-14",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 11,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-15",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-16",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-17",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-18",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 1K × 3, 400m 조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 두 번째 이후 페이스 무너지면 종료.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-19",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-20",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 12.0,
    "workout": "워밍업 2km + MP 지속주 9km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-21",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 12,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-22",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-23",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-24",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-25",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 40분 + 100m 스트라이드 3회. Easy 7'20~8'10/km, 스트라이드는 전력질주가 아니라 다리 리듬 확인.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-26",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-27",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-28",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 13,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-29",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-30",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 23.0,
    "workout": "2시간 45분 LSD. 7'05~7'35/km, 후반 자세 유지. 더우면 시간 10~15% 단축 가능.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-08-31",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-01",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 7.5,
    "workout": "워밍업 2km + 400m × 8, 200m 조깅 회복 + 쿨다운 2km. 목표 5'25~5'45/km, 호흡 무너지면 6회로 감량.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-02",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-03",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 10.0,
    "workout": "총 10km 빌드업. 7'20/km 안팎에서 시작해 마지막 1~2km만 6'10~6'20/km. 급가속 금지.",
    "pace_guide": "빌드업 마지막 6'10~6'20/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-04",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 14,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-05",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-06",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-07",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-08",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 800m × 4, 400m 조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 더우면 3회로 감량.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-09",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-10",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 9.0,
    "workout": "워밍업 2km + MP 지속주 6km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-11",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 15,
    "phase": "2단계 역치·지구력 강화",
    "plan_date": "2026-09-12",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-13",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 20.0,
    "workout": "20km 거리주. 전반은 7'05~7'30/km, 후반 5km만 MP 감각 6'05~6'12/km. 보급 필수.",
    "pace_guide": "LSD + 후반 MP 6'05~6'12/km",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-14",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-15",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 40분 + 100m 스트라이드 3회. Easy 7'20~8'10/km, 스트라이드는 전력질주가 아니라 다리 리듬 확인.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-16",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-17",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 8.0,
    "workout": "워밍업 2km + 템포런 4km + 쿨다운 2km. 목표 5'45~5'55/km, 더우면 6'00/km 전후.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-18",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 16,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-19",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-20",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 30.0,
    "workout": "상암 30km 거리주. 전반 7'05~7'30/km로 안정, 25km 이후 자세 유지. 젤·수분은 40~45분마다 실전처럼.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-21",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-22",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "회복 조깅 40~50분. 7'40~8'30/km 또는 RPE 2~3. 피로하면 완전휴식으로 전환.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-23",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-24",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 8.0,
    "workout": "워밍업 2km + MP 지속주 5km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-25",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 17,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-26",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-27",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 25.0,
    "workout": "25km 거리주. 7'05~7'35/km 범위에서 후반 무너지지 않는 것이 목표. MP 집착 금지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-28",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-29",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m × 6, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 기록보다 자세.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-09-30",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-01",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 40분 + 스트라이드 3회. 일요일 장거리 대비용 회복 자극, 숨차게 하지 않기.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-02",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 18,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-03",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-04",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 32.0,
    "workout": "일마 자체대회. 32K 선택 시 마라톤 리허설로 진행하되 초반 7'00/km 전후, 후반만 6'15~6'25/km 확인. 10K 선택 시 전력질주 금지.",
    "pace_guide": "Easy/LSD 기준",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-05",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-06",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 40분 + 100m 스트라이드 3회. Easy 7'20~8'10/km, 스트라이드는 전력질주가 아니라 다리 리듬 확인.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-07",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소+보강",
    "planned_km": 8.0,
    "workout": "Easy 8km + 보강 A/B 1~2세트. 화요일 포인트 다음날이므로 페이스 욕심 금지.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "몸이 무거우면 6km 또는 휴식"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-08",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 9.0,
    "workout": "워밍업 2km + MP 지속주 6km + 쿨다운 1~2km. 목표 6'05~6'12/km, 더우면 6'15~6'25/km까지 허용.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-09",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 6.0,
    "workout": "회복 조깅 6km + 종아리·둔근 스트레칭 10분. 목요일 포인트 피로를 풀되 기록 욕심 금지.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "짧게 때우기보다 확실히 회복"
  },
  {
    "week_no": 19,
    "phase": "3단계 실전·후반 유지",
    "plan_date": "2026-10-10",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-11",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 21.0,
    "workout": "2시간 30분 LSD. 7'05~7'35/km, 킨텍스 언덕 포함 시 오르막 페이스 집착 금지. 대화 가능한 강도 유지.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-12",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-13",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 800m × 3, 400m 걷기/조깅 회복 + 쿨다운 2km. 목표 5'35~5'50/km, 마지막까지 자세 유지.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-14",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소",
    "planned_km": 6.0,
    "workout": "Easy 6km. 보강은 생략하거나 코어 1세트만. 다리를 무겁게 만들지 않기.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "테이퍼 구간은 회복 우선"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-15",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 7.0,
    "workout": "워밍업 2km + 템포런 3km + 쿨다운 2km. 목표 5'45~5'55/km 또는 RPE 7. 완주가 불안하면 1.5km × 2로 분할.",
    "pace_guide": "템포/LT 5'45~6'00/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-16",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 5.0,
    "workout": "회복 조깅 5~6km 또는 완전휴식. 다리가 무거우면 쉬는 쪽 선택.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "테이퍼 구간은 피로 제거"
  },
  {
    "week_no": 20,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-17",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-18",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 17.0,
    "workout": "2시간 LSD. 7'05~7'35/km, 기온 높으면 7'40/km까지 허용. 심박·호흡 안정 우선.",
    "pace_guide": "LSD 7'05~7'35/km, RPE 3~4",
    "coach_note": "하계훈련계획 거북이팀 기준. 보급·수분·페이스 통제"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-19",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-20",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 6.5,
    "workout": "워밍업 2km + 400m 반복, 200m 걷기/조깅 회복 + 쿨다운 1.5~2km. 목표 5'25~5'45/km, 전력질주 금지.",
    "pace_guide": "400m 5'25~5'45/km, 회복 충분히",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-21",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "유산소",
    "planned_km": 6.0,
    "workout": "Easy 6km. 보강은 생략하거나 코어 1세트만. 다리를 무겁게 만들지 않기.",
    "pace_guide": "6'50~7'40/km, 더우면 +10~40초",
    "coach_note": "테이퍼 구간은 회복 우선"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-22",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 6.0,
    "workout": "회복 조깅 30분 + MP 감각 2km. MP는 6'05~6'12/km, 피로하면 1km만.",
    "pace_guide": "MP 6'05~6'12/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-23",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "회복 조깅",
    "planned_km": 5.0,
    "workout": "회복 조깅 5~6km 또는 완전휴식. 다리가 무거우면 쉬는 쪽 선택.",
    "pace_guide": "7'40~8'30/km 또는 휴식",
    "coach_note": "테이퍼 구간은 피로 제거"
  },
  {
    "week_no": 21,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-24",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-25",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 9.0,
    "workout": "레이스 1주 전 Easy 8~10km + 100m 스트라이드 3회. 힘 남기고 종료.",
    "pace_guide": "레이스 1주 전 자극",
    "coach_note": "가볍게 다리만 깨우기"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-26",
    "day_name": "월",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 전날 일요일 훈련 흡수일. 조깅·보강 없이 쉬기.",
    "pace_guide": "휴식",
    "coach_note": "쉬는 날은 진짜 쉬기"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-27",
    "day_name": "화",
    "division": "거북팀 공식",
    "workout_type": "화 포인트",
    "planned_km": 5.0,
    "workout": "회복 조깅 40분 + 100m 스트라이드 3회. Easy 7'20~8'10/km, 스트라이드는 전력질주가 아니라 다리 리듬 확인.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 컨디션에 따라 세트 수 10~30% 감량"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-28",
    "day_name": "수",
    "division": "개인 조절",
    "workout_type": "레이스 주간 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식 또는 20~30분 산책. 레이스 주간은 수면·탄수화물·컨디션 우선.",
    "pace_guide": "휴식",
    "coach_note": "보충훈련 금지"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-29",
    "day_name": "목",
    "division": "거북팀 공식",
    "workout_type": "목 포인트",
    "planned_km": 0.0,
    "workout": "휴식 또는 20분 조깅. 레이스 주간은 컨디션 우선, 보충훈련 금지.",
    "pace_guide": "Easy 7'20~8'10/km",
    "coach_note": "팀 훈련 고정. 워밍업·쿨다운 포함, 무리하면 거리 감량"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-30",
    "day_name": "금",
    "division": "개인 조절",
    "workout_type": "레이스 주간 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 목요일 컨디션 확인 후 회복. 수면·수분·장비 준비.",
    "pace_guide": "휴식",
    "coach_note": "보충훈련 금지"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-10-31",
    "day_name": "토",
    "division": "개인 조절",
    "workout_type": "고정 휴식",
    "planned_km": 0.0,
    "workout": "완전휴식. 일요일 팀 롱런을 위한 준비일. 장거리 전날 하체 보강 금지.",
    "pace_guide": "휴식",
    "coach_note": "내일 훈련을 위한 절제"
  },
  {
    "week_no": 22,
    "phase": "테이퍼·컨디션 조율",
    "plan_date": "2026-11-01",
    "day_name": "일",
    "division": "거북팀 공식",
    "workout_type": "일 LSD/롱런/레이스",
    "planned_km": 42.2,
    "workout": "마라톤 레이스. 목표 4:19:00~4:20:00 언더, 평균 6'09/km 전후. 초반 5km는 6'12~6'18/km로 차분하게, 30km 이후 몸 상태를 보고 유지.",
    "pace_guide": "레이스: 평균 6'09/km 전후",
    "coach_note": "보급은 35~40분마다, 오버페이스 금지"
  }
]
$seed$::jsonb) as x(
  week_no int,
  phase text,
  plan_date date,
  day_name text,
  division text,
  workout_type text,
  planned_km numeric,
  workout text,
  pace_guide text,
  coach_note text
);

-- 설치 확인용 조회
select '설치 완료' as status,
       (select count(*) from training_plan) as training_plan_count,
       (select count(*) from app_members) as member_count;
-- 관리자 웹앱 훈련표 수정/추가/삭제 기능 패치 SQL
-- 기존 데이터는 삭제하지 않습니다.
-- Supabase > SQL Editor > New query 에 전체 붙여넣고 Run 하세요.

create or replace function admin_save_plan(
  p_token uuid,
  p_plan_id uuid,
  p_week_no int,
  p_phase text,
  p_plan_date date,
  p_day_name text,
  p_division text,
  p_workout_type text,
  p_planned_km numeric,
  p_workout text,
  p_pace_guide text,
  p_coach_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan training_plan%rowtype;
  v_day text;
  v_planned numeric := coalesce(p_planned_km, 0);
begin
  perform require_admin(p_token);

  if p_plan_date is null then
    raise exception '훈련 날짜를 입력해주세요.';
  end if;

  if v_planned < 0 then
    raise exception '계획 거리는 0 이상이어야 합니다.';
  end if;

  v_day := coalesce(nullif(trim(p_day_name), ''),
    case extract(dow from p_plan_date)::int
      when 0 then '일'
      when 1 then '월'
      when 2 then '화'
      when 3 then '수'
      when 4 then '목'
      when 5 then '금'
      when 6 then '토'
    end
  );

  if p_plan_id is null then
    insert into training_plan(
      week_no, phase, plan_date, day_name, division, workout_type, planned_km, workout, pace_guide, coach_note
    ) values (
      coalesce(p_week_no, 0), nullif(trim(p_phase), ''), p_plan_date, v_day, nullif(trim(p_division), ''),
      nullif(trim(p_workout_type), ''), v_planned, nullif(trim(p_workout), ''), nullif(trim(p_pace_guide), ''), nullif(trim(p_coach_note), '')
    )
    returning * into v_plan;
  else
    update training_plan
    set
      week_no = coalesce(p_week_no, week_no),
      phase = nullif(trim(p_phase), ''),
      plan_date = p_plan_date,
      day_name = v_day,
      division = nullif(trim(p_division), ''),
      workout_type = nullif(trim(p_workout_type), ''),
      planned_km = v_planned,
      workout = nullif(trim(p_workout), ''),
      pace_guide = nullif(trim(p_pace_guide), ''),
      coach_note = nullif(trim(p_coach_note), '')
    where id = p_plan_id
    returning * into v_plan;

    if not found then
      raise exception '수정할 훈련표를 찾을 수 없습니다.';
    end if;
  end if;

  return to_jsonb(v_plan);
end;
$$;

create or replace function admin_delete_plan(p_token uuid, p_plan_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  perform require_admin(p_token);

  delete from training_plan
  where id = p_plan_id;

  get diagnostics v_count = row_count;

  if v_count = 0 then
    raise exception '삭제할 훈련표가 없습니다.';
  end if;

  return true;
end;
$$;

grant execute on function admin_save_plan(uuid, uuid, int, text, date, text, text, text, numeric, text, text, text) to anon, authenticated;
grant execute on function admin_delete_plan(uuid, uuid) to anon, authenticated;
