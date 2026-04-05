-- # ==========================================================
-- # preparation
-- # ==========================================================
create extension if not exists dblink;
create extension if not exists citus;
show wal_level;

drop table if exists app_users cascade;
drop table if exists app_users_distributed cascade;

create table app_users (
    id uuid primary key default gen_random_uuid(),
    name varchar,
    balance numeric
);

create table app_users_distributed (
    id uuid primary key default gen_random_uuid(),
    name varchar,
    balance numeric
);


-- # ==========================================================
-- # sharding
-- # ==========================================================
select citus_set_coordinator_host('coordinator-1', 5432);

select * from master_add_node('worker-1-0.worker-1-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('worker-1-1.worker-1-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('worker-1-2.worker-1-headless.citus.svc.cluster.local', 5432);

select * from master_get_active_worker_nodes();

set citus.shard_count = 32;
set citus.shard_replication_factor = 1;

select create_distributed_table('app_users_distributed', 'id');
select * from pg_dist_partition;
select * from pg_dist_shard;


-- # ==========================================================
-- # trigger
-- # ==========================================================
create or replace function sync_to_distributed()
returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        insert into public.app_users_distributed (id, name, balance)
        values (new.id, new.name, new.balance)
        on conflict (id) do update
            set name    = excluded.name,
                balance = excluded.balance;
        return new;

    elsif tg_op = 'UPDATE' then
        update public.app_users_distributed
        set name    = new.name,
            balance = new.balance
        where id = old.id;
        return new;

    elsif tg_op = 'DELETE' then
        delete from public.app_users_distributed
        where id = old.id;
        return old;
    end if;
end;
$$;


create trigger trg_sync
before insert or update or delete on app_users
for each row execute function sync_to_distributed();

begin;
set local citus.enable_ddl_propagation to off;
alter table app_users enable replica trigger trg_sync;
commit;


-- # ==========================================================
-- # replication
-- # ==========================================================
drop subscription if exists coord1_sub_from_master1;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'repl_user') then
        create role repl_user with login replication password '111';
    end if;
end
$$;

create subscription coord1_sub_from_master1
connection 'host=master-1.citus.svc.cluster.local port=5432 dbname=postgres user=repl_user password=111'
publication master1_pub_app
with (copy_data = false);

select * from pg_stat_subscription;
select * from pg_subscription_rel;

select count(*) from app_users;
select count(*) from app_users_distributed;

