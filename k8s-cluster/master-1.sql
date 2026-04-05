-- # ==========================================================
-- # preparation
-- # ==========================================================
create extension if not exists dblink;
create extension if not exists citus;
show wal_level;

drop table if exists app_users;
create table app_users(
    id uuid primary key default gen_random_uuid(),
    name varchar,
    balance numeric
);

-- # ==========================================================
-- # replication
-- # ==========================================================
drop publication if exists master1_pub_app;
drop subscription if exists master1_sub_from_master2;
drop subscription if exists master1_sub_from_master3;

create role repl_user with login replication password '111';

create publication master1_pub_app
for table app_users;

create subscription master1_sub_from_master2
connection 'host=master-2.citus.svc.cluster.local port=5432 dbname=postgres user=repl_user password=111'
publication master2_pub_app
with (origin = none, copy_data = false);

create subscription master1_sub_from_master3
connection 'host=master-3.citus.svc.cluster.local port=5432 dbname=postgres user=repl_user password=111'
publication master3_pub_app
with (origin = none, copy_data = false);

select * from pg_stat_subscription;
select * from pg_subscription_rel;

-- # ==========================================================
-- # test
-- # ==========================================================
insert into app_users (name, balance) values ('test-now', 777);

insert into app_users (name, balance)
select 
    'user-' || i,
    (random() * 10000)::numeric(10,2)
from generate_series(1, 1000000) as i;

select count(*) from app_users;

-- # ==========================================================
-- # callers
-- # ==========================================================
create or replace function locker_call_try_lock(
    p_table_name text,
    p_key_text   text
)
returns void
language plpgsql
as $func$
declare
    coord_id int := 1;
begin
    perform dblink_exec(
        'host=pg-locker.citus.svc.cluster.local port=5432 dbname=postgres user=postgres password=111',
        format(
            $$do $d$ begin perform locker.try_lock(%L, %L, %s); end $d$;$$,
            p_table_name, p_key_text, coord_id
        )
    );
end;
$func$;

create or replace function locker_call_release_lock(
    p_table_name text,
    p_key_text   text
)
returns void
language plpgsql
as $func$
declare
    coord_id int := 1;
begin
    perform dblink_exec(
        'host=pg-locker.citus.svc.cluster.local port=5432 dbname=postgres user=postgres password=111',
        format(
            $$do $d$ begin perform locker.release_lock(%L, %L, %s); end $d$;$$,
            p_table_name, p_key_text, coord_id
        )
    );
end;
$func$;