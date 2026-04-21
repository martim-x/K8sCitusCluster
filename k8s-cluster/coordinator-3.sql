-- # ==========================================================
-- # preparation
-- # ==========================================================
create extension if not exists dblink;
create extension if not exists citus;
show wal_level;

drop table if exists app_users cascade;
drop table if exists app_users_distributed cascade;

create table app_users(
    id uuid primary key default gen_random_uuid(),
    name varchar,
    balance numeric
);

create table app_users_distributed(
    id uuid primary key default gen_random_uuid(),
    name varchar,
    balance numeric
);


-- # ==========================================================
-- # sharding
-- # ==========================================================
select citus_set_coordinator_host('coordinator-3', 5432);

select * from master_add_node('worker-3-0.worker-3-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('worker-3-1.worker-3-headless.citus.svc.cluster.local', 5432);
select * from master_add_node('worker-3-2.worker-3-headless.citus.svc.cluster.local', 5432);

select * from master_get_active_worker_nodes();

set citus.shard_count = 32;
set citus.shard_replication_factor = 2;

select create_distributed_table('app_users_distributed', 'id');
select * from pg_dist_partition;
select * from pg_dist_shard;

SELECT
    s.logicalrelid::regclass AS table_name,
    s.shardid,
    p.shardstate,
    n.nodename,
    n.nodeport
FROM pg_dist_shard       AS s
JOIN pg_dist_placement   AS p ON s.shardid = p.shardid
JOIN pg_dist_node        AS n ON p.groupid = n.groupid
WHERE s.logicalrelid = 'app_users_distributed'::regclass
  AND n.noderole = 'primary'
ORDER BY s.shardid, n.nodename, n.nodeport;

-- # ==========================================================
-- # trigger
-- # ==========================================================
create or replace function sync_incoming_to_distributed()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'INSERT' then
        insert into public.app_users_distributed (id, name, balance)
        values (new.id, new.name, new.balance)
        on conflict (id) do update
        set name = excluded.name,
            balance = excluded.balance;
        return new;

    elsif tg_op = 'UPDATE' then
        update public.app_users_distributed
        set name = new.name,
            balance = new.balance
        where id = old.id;
        return new;

    elsif tg_op = 'DELETE' then
        delete from public.app_users_distributed
        where id = old.id;
        return old;
    end if;

    return null;
end;
$$;

drop trigger if exists trg_sync_incoming on app_users;

create trigger trg_sync_incoming
before insert or update or delete on app_users
for each row execute function sync_incoming_to_distributed();

begin;
set local citus.enable_ddl_propagation to off;
alter table app_users enable always trigger trg_sync_incoming;
commit;


-- # ==========================================================
-- # replication
-- # ==========================================================
alter subscription coord3_sub_from_master3 disable;

alter subscription coord3_sub_from_master3
set (slot_name = none);

drop subscription coord3_sub_from_master3;


do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'repl_user') then
        create role repl_user with login replication password '111';
    end if;
end
$$;

create subscription coord3_sub_from_master3
connection 'host=master-3.citus.svc.cluster.local port=5432 dbname=postgres user=repl_user password=111'
publication master3_pub_app
with (origin=any, copy_data = false);

select * from pg_stat_subscription;
select * from pg_subscription_rel;

select count(*) from app_users;
select count(*) from app_users_distributed;


