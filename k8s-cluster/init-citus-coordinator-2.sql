create extension if not exists dblink;

-- # ==========================================================
-- # callers
-- # ==========================================================

-- call_try_lock
create or replace function locker_call_try_lock(
    p_table_name text,
    p_key_text   text
)
returns void
language plpgsql
as $func$
declare
    coord_id int := 2;  -- для coord-2
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


-- call_release_lock
create or replace function locker_call_release_lock(
    p_table_name text,
    p_key_text   text
)
returns void
language plpgsql
as $func$
declare
    coord_id int := 2;
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


-- # ==========================================================
-- # triggers
-- # ==========================================================

-- trigger_lock_before
create or replace function lock_before()
returns trigger
language plpgsql
as $func$
declare
    v_key_text text;
    v_table_name text;
begin
    if TG_NARGS <> 1 then
        raise exception 'lock_* trigger requires exactly 1 arg: table_name' 
            using errcode = 'invalid_parameter_value';
    end if;

    v_table_name := TG_ARGV[0];

    if v_table_name <> TG_TABLE_NAME then
        raise exception 'lock_* trigger arg table_name="%" does not match actual table name="%"',
            v_table_name, TG_TABLE_NAME
            using errcode = 'invalid_parameter_value';
    end if;

    if tg_op = 'INSERT' then
        v_key_text := new.id::text;
    elsif tg_op = 'UPDATE' then
        v_key_text := coalesce(new.id, old.id)::text;
    elsif tg_op = 'DELETE' then
        v_key_text := old.id::text;
    end if;

    perform locker_call_try_lock(v_table_name, v_key_text);

    return new;
end;
$func$;


drop trigger if exists trg_app_users_lock_before on public.app_users;

create trigger trg_app_users_lock_before
before insert or update or delete on public.app_users
for each row
execute function lock_before('app_users');


-- trigger_lock_after
create or replace function lock_after()
returns trigger
language plpgsql
as $func$
declare
    v_key_text   text;
    v_table_name text;
begin
    if TG_NARGS <> 1 then
        raise exception 'lock_* trigger requires exactly 1 arg: table_name' 
            using errcode = 'invalid_parameter_value';
    end if;

    v_table_name := TG_ARGV[0];

    if v_table_name <> TG_TABLE_NAME then
        raise exception 'lock_* trigger arg table_name="%" does not match actual table name="%"',
            v_table_name, TG_TABLE_NAME
            using errcode = 'invalid_parameter_value';
    end if;

    if tg_op = 'INSERT' then
        v_key_text := new.id::text;
    elsif tg_op = 'UPDATE' then
        v_key_text := coalesce(new.id, old.id)::text;
    elsif tg_op = 'DELETE' then
        v_key_text := old.id::text;
    end if;

    perform locker_call_release_lock(v_table_name, v_key_text);

    return new;
end;
$func$;


drop trigger if exists trg_app_users_lock_after on public.app_users;

create trigger trg_app_users_lock_after
after insert or update or delete on public.app_users
for each row
execute function lock_after('app_users');


-- # ==========================================================
-- # test
-- # ==========================================================
select count(*)
from pg_stat_activity
where state = 'idle in transaction'


drop table app_users

create table app_users(
	id uuid primary key default gen_random_uuid(),
	name varchar,
	balance numeric
);

insert into app_users (name, balance) values
    ('user-6', 100),
    ('user-7', 200),
    ('user-8', 300),
    ('user-9', 400),
    ('user-10', 500);

update app_users
set balance = balance + 10
where id = '81361c01-94af-4ca9-9d0b-5e71fbd6c507';


select * from app_users

-- # ==========================================================
-- # replication
-- # ==========================================================
create role repl_user with login replication password '111';


create table app_users(
	id uuid primary key default gen_random_uuid(),
	name varchar,
	balance numeric
);



drop publication coord2_pub_app
drop subscription coord2_sub_from_coord1

create publication coord2_pub_app
for table app_users;

create subscription coord2_sub_from_coord1
connection 'host=citus-coordinator-1.citus port=5432 dbname=postgres user=repl_user password=111'
publication coord1_pub_app
with (origin = none, copy_data = false);


select * from pg_subscription;
select * from pg_stat_subscription;



-- # ==========================================================
-- # sharding
-- # ==========================================================
create extension if not exists citus;


select * from master_add_node('citus-worker-2-0.citus-worker-2-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('citus-worker-2-1.citus-worker-2-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('citus-worker-2-2.citus-worker-2-headless.citus.svc.cluster.local', 5432);


select * from master_get_active_worker_nodes();



SELECT create_distributed_table('app_users', 'id');
SELECT * FROM pg_dist_partition;
SELECT * FROM pg_dist_shard;



show server_version;
show wal_level;
show max_replication_slots;
show max_wal_senders;

alter system set wal_level = 'logical';
alter system set max_replication_slots = 10;
alter system set max_wal_senders  = 10;

