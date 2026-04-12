-- ============================================================
-- warn: drop functions before tables
-- ============================================================
-- drop function if exists set_entity_lifecycle(text, uuid, boolean);
-- drop function if exists validate_exists_by_id(text, uuid);
-- drop function if exists is_record_active(text, uuid);
-- drop function if exists sanitize_text(text, text);


-- ============================================================
-- warn: drop tables in reverse dependency order
-- ============================================================
-- drop table if exists app_order_status_histories cascade;
-- drop table if exists app_request_status_histories cascade;
-- drop table if exists app_statuses cascade;

-- drop table if exists app_orders cascade;
-- drop table if exists app_requests cascade;

-- drop table if exists profile_filter_brands cascade;
-- drop table if exists profile_filter_drive_types cascade;
-- drop table if exists profile_filter_transmission_types cascade;
-- drop table if exists profile_filter_usage_types cascade;
-- drop table if exists profile_filter_capacities cascade;

-- drop table if exists app_user_profile_cars cascade;
-- drop table if exists cars cascade;

-- drop table if exists capacities cascade;
-- drop table if exists capacity_types cascade;
-- drop table if exists drive_types cascade;
-- drop table if exists transmission_types cascade;
-- drop table if exists usage_types cascade;
-- drop table if exists brands cascade;

-- drop table if exists app_users cascade;
-- drop table if exists app_user_profiles cascade;
-- drop table if exists app_roles cascade;


-- ============================================================
-- UTILS
-- ============================================================


create or replace function sanitize_text(
    p_value      text,
    p_field_name text default 'field'
)
returns text
language plpgsql
as $$
declare
    v_clean text;
begin
    v_clean := trim(p_value);

    if v_clean is null or v_clean = '' then
        raise exception 'sanitize_text: % must not be empty', p_field_name;
    end if;

    return v_clean;
end;
$$;


create or replace function is_record_active(
    p_table_name text,
    p_id         uuid
)
returns boolean
language plpgsql
as $$
declare
    v_exists      boolean;
    v_has_deleted boolean;
begin
    select exists(
        select 1
        from information_schema.columns
        where table_schema = current_schema()
          and table_name   = p_table_name
          and column_name  = 'is_deleted'
    ) into v_has_deleted;

    if v_has_deleted then
        execute format(
            'select exists(select 1 from %I where id = $1 and is_deleted = false)',
            p_table_name
        )
        into v_exists
        using p_id;
    else
        execute format(
            'select exists(select 1 from %I where id = $1)',
            p_table_name
        )
        into v_exists
        using p_id;
    end if;

    return coalesce(v_exists, false);
exception
    when others then
        return false;
end;
$$;


create or replace function validate_exists_by_id(
    p_table_name text,
    p_id         uuid
)
returns void
language plpgsql
as $$
begin
    if not is_record_active(p_table_name, p_id) then
        raise exception
            'validate_exists_by_id: record not found or deleted in %.id = %',
            p_table_name, p_id;
    end if;
end;
$$;


create or replace function set_entity_lifecycle(
    p_table_name text,
    p_id         uuid,
    p_is_deleted boolean
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    execute format(
        'update %I set is_deleted = $1 where id = $2 returning id',
        p_table_name
    )
    into v_id
    using p_is_deleted, p_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- APP_ROLE
-- ============================================================
create table app_roles (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_app_role_id_hash
    on app_roles using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_app_role(
    p_name varchar(100)
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name := sanitize_text(p_name, 'name');

    -- [note] если запись с таким name уже есть но soft-deleted → восстанавливаем
    select id into v_id
    from app_roles
    where name = p_name and is_deleted = true;

    if found then
        return set_entity_lifecycle('app_roles', v_id, false);
    end if;

    insert into app_roles (name)
    values (p_name)
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_app_roles()
returns setof app_roles
language plpgsql
as $$
begin
    return query
    select * from app_roles
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_app_role_by_uuid(
    p_id uuid
)
returns app_roles
language plpgsql
as $$
declare
    v_row app_roles;
begin
    select * into v_row
    from app_roles
    where id = p_id and is_deleted = false;

    return v_row;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_app_role_by_uuid(
    p_id   uuid,
    p_name varchar(100)
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name := sanitize_text(p_name, 'name');

    update app_roles
    set name = p_name
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- delete 1 (soft)
-- -------------------------------
create or replace function delete_app_role_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_roles', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function restore_app_role_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_roles', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- APP_USER_PROFILE
-- ============================================================
create table app_user_profiles (
    id          uuid         primary key default uuidv7(),

    name        varchar(100) not null,
    is_deleted  boolean      not null default false,

    app_role_id uuid         not null references app_roles(id)
);

create index idx_app_user_profile_id_hash
    on app_user_profiles using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_app_user_profile(
    p_name        varchar(100),
    p_app_role_id uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name := sanitize_text(p_name, 'name');

    -- [validate fk] бросит exception если app_roles не существует или удалён
    perform validate_exists_by_id('app_roles', p_app_role_id);

    -- [note] если профиль с таким name удалён → восстанавливаем и обновляем роль
    select id into v_id
    from app_user_profiles
    where name = p_name and is_deleted = true;

    if found then
        update app_user_profiles
        set is_deleted  = false,
            app_role_id = p_app_role_id
        where id = v_id
        returning id into v_id;

        return v_id;
    end if;

    -- [fix] values (p_name, select id from ...) — невалидный синтаксис.
    --       FK-ограничение на таблице гарантирует целостность,
    --       validate_exists_by_id уже проверил существование выше.
    insert into app_user_profiles (name, app_role_id)
    values (p_name, p_app_role_id)
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_app_user_profiles()
returns setof app_user_profiles
language plpgsql
as $$
begin
    return query
    select * from app_user_profiles
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_app_user_profile_by_uuid(
    p_id uuid
)
returns app_user_profiles
language plpgsql
as $$
declare
    v_row app_user_profiles;
begin
    select * into v_row
    from app_user_profiles
    where id = p_id and is_deleted = false;

    return v_row;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_app_user_profile_by_uuid(
    p_id          uuid,
    p_name        varchar(100),
    p_app_role_id uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name := sanitize_text(p_name, 'name');

    -- [validate fk]
    perform validate_exists_by_id('app_roles', p_app_role_id);

    update app_user_profiles
    set name        = p_name,
        app_role_id = p_app_role_id
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- delete 1 (soft)
-- -------------------------------
create or replace function delete_app_user_profile_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_user_profiles', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function restore_app_user_profile_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_user_profiles', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- APP_USER
-- ============================================================
create table app_users (
    id                  uuid         primary key default uuidv7(),

    email               varchar(250) unique not null,
    password            varchar(128) not null,
    is_deleted          boolean      not null default false,

    app_user_profile_id uuid         not null references app_user_profiles(id)
);

create index idx_app_user_id_hash
    on app_users using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_app_user(
    p_email               varchar(250),
    p_password            varchar(128),
    p_app_user_profile_id uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize] email — trim + empty check
    -- [note] пароль намеренно не sanitize — trim ломает хэш
    p_email := sanitize_text(p_email, 'email');

    -- [validate fk]
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);

    -- [note] email уже есть но soft-deleted → восстанавливаем
    select id into v_id
    from app_users
    where email = p_email and is_deleted = true;

    if found then
        update app_users
        set is_deleted          = false,
            password            = p_password,
            app_user_profile_id = p_app_user_profile_id
        where id = v_id
        returning id into v_id;

        return v_id;
    end if;

    insert into app_users (email, password, app_user_profile_id)
    values (p_email, p_password, p_app_user_profile_id)
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_app_users()
returns setof app_users
language plpgsql
as $$
begin
    return query
    select * from app_users
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_app_user_by_uuid(
    p_id uuid
)
returns app_users
language plpgsql
as $$
declare
    v_row app_users;
begin
    select * into v_row
    from app_users
    where id = p_id and is_deleted = false;

    return v_row;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_app_user_by_uuid(
    p_id                  uuid,
    p_email               varchar(250),
    p_password            varchar(128),
    p_app_user_profile_id uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize] email
    p_email := sanitize_text(p_email, 'email');

    -- [validate fk]
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);

    update app_users
    set email               = p_email,
        password            = p_password,
        app_user_profile_id = p_app_user_profile_id
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- delete 1 (soft)
-- -------------------------------
create or replace function delete_app_user_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_users', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function restore_app_user_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return set_entity_lifecycle('app_users', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- BRAND
-- ============================================================
create table brands (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_brand_id_hash
    on brands using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_brand(p_name varchar(100))
returns uuid language plpgsql as $$
declare
    v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');

    select id into v_id from brands
    where name = p_name and is_deleted = true;

    if found then
        return set_entity_lifecycle('brands', v_id, false);
    end if;

    insert into brands (name) values (p_name) returning id into v_id;
    return v_id;
exception
    when others then return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_brands()
returns setof brands language plpgsql as $$
begin
    return query select * from brands where is_deleted = false;
exception
    when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_brand_by_uuid(p_id uuid)
returns brands language plpgsql as $$
declare
    v_row brands;
begin
    select * into v_row from brands where id = p_id and is_deleted = false;
    return v_row;
exception
    when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_brand_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare
    v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update brands set name = p_name
    where id = p_id and is_deleted = false
    returning id into v_id;
    return v_id;
exception
    when others then return null;
end;
$$;

-- -------------------------------
-- delete 1 (soft) / restore 1
-- -------------------------------
create or replace function delete_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return set_entity_lifecycle('brands', p_id, true);
exception
    when others then return null;
end;
$$;

create or replace function restore_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return set_entity_lifecycle('brands', p_id, false);
exception
    when others then return null;
end;
$$;


-- ============================================================
-- DRIVE_TYPE
-- ============================================================
create table drive_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_drive_type_id_hash
    on drive_types using hash (id);

create or replace function create_drive_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    select id into v_id from drive_types where name = p_name and is_deleted = true;
    if found then return set_entity_lifecycle('drive_types', v_id, false); end if;
    insert into drive_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_drive_types()
returns setof drive_types language plpgsql as $$
begin
    return query select * from drive_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function get_drive_type_by_uuid(p_id uuid)
returns drive_types language plpgsql as $$
declare v_row drive_types;
begin
    select * into v_row from drive_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function update_drive_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update drive_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function delete_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('drive_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('drive_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- TRANSMISSION_TYPE
-- ============================================================
create table transmission_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_transmission_type_id_hash
    on transmission_types using hash (id);

create or replace function create_transmission_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    select id into v_id from transmission_types where name = p_name and is_deleted = true;
    if found then return set_entity_lifecycle('transmission_types', v_id, false); end if;
    insert into transmission_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_transmission_types()
returns setof transmission_types language plpgsql as $$
begin
    return query select * from transmission_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function get_transmission_type_by_uuid(p_id uuid)
returns transmission_types language plpgsql as $$
declare v_row transmission_types;
begin
    select * into v_row from transmission_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function update_transmission_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update transmission_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function delete_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('transmission_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('transmission_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- USAGE_TYPE
-- ============================================================
create table usage_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_usage_type_id_hash
    on usage_types using hash (id);

create or replace function create_usage_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    select id into v_id from usage_types where name = p_name and is_deleted = true;
    if found then return set_entity_lifecycle('usage_types', v_id, false); end if;
    insert into usage_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_usage_types()
returns setof usage_types language plpgsql as $$
begin
    return query select * from usage_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function get_usage_type_by_uuid(p_id uuid)
returns usage_types language plpgsql as $$
declare v_row usage_types;
begin
    select * into v_row from usage_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function update_usage_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update usage_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function delete_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('usage_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('usage_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAPACITY_TYPE
-- ============================================================
create table capacity_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_capacity_type_id_hash
    on capacity_types using hash (id);

create or replace function create_capacity_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    select id into v_id from capacity_types where name = p_name and is_deleted = true;
    if found then return set_entity_lifecycle('capacity_types', v_id, false); end if;
    insert into capacity_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_capacity_types()
returns setof capacity_types language plpgsql as $$
begin
    return query select * from capacity_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function get_capacity_type_by_uuid(p_id uuid)
returns capacity_types language plpgsql as $$
declare v_row capacity_types;
begin
    select * into v_row from capacity_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function update_capacity_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update capacity_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function delete_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('capacity_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('capacity_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAPACITY
-- ============================================================
create table capacities (
    id               uuid    primary key default uuidv7(),

    value            int     not null check (value > 0),
    is_deleted       boolean not null default false,

    capacity_type_id uuid    not null references capacity_types(id)
);

create index idx_capacity_id_hash
    on capacities using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_capacity(
    p_value            int,
    p_capacity_type_id uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [validate fk]
    perform validate_exists_by_id('capacity_types', p_capacity_type_id);

    -- [note] та же пара value+capacity_type_id удалена → восстанавливаем
    select id into v_id
    from capacities
    where value = p_value
      and capacity_type_id = p_capacity_type_id
      and is_deleted = true;

    if found then
        return set_entity_lifecycle('capacities', v_id, false);
    end if;

    insert into capacities (value, capacity_type_id)
    values (p_value, p_capacity_type_id)
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_capacities()
returns setof capacities language plpgsql as $$
begin
    return query select * from capacities where is_deleted = false;
exception when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_capacity_by_uuid(p_id uuid)
returns capacities language plpgsql as $$
declare v_row capacities;
begin
    select * into v_row from capacities where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_capacity_by_uuid(
    p_id               uuid,
    p_value            int,
    p_capacity_type_id uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('capacity_types', p_capacity_type_id);
    update capacities
    set value            = p_value,
        capacity_type_id = p_capacity_type_id
    where id = p_id and is_deleted = false
    returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

-- -------------------------------
-- delete 1 (soft) / restore 1
-- -------------------------------
create or replace function delete_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('capacities', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('capacities', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAR
-- ============================================================
create table cars (
    id                   uuid           primary key default uuidv7(),

    name                 varchar(100)   not null,
    price_of_origin      numeric(12, 2) not null check (price_of_origin > 0),
    manufacture_date     date           not null,
    country_of_origin    varchar(100)   not null,
    description          text           not null,
    is_deleted           boolean        not null default false,

    brand_id             uuid           not null references brands(id),
    drive_type_id        uuid           not null references drive_types(id),
    transmission_type_id uuid           not null references transmission_types(id),
    usage_type_id        uuid           not null references usage_types(id),
    capacity_id          uuid           not null references capacities(id)
);

create index idx_car_id_hash
    on cars using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_car(
    p_name                 varchar(100),
    p_price_of_origin      numeric(12, 2),
    p_manufacture_date     date,
    p_country_of_origin    varchar(100),
    p_description          text,
    p_brand_id             uuid,
    p_drive_type_id        uuid,
    p_transmission_type_id uuid,
    p_usage_type_id        uuid,
    p_capacity_id          uuid
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name             := sanitize_text(p_name,             'name');
    p_country_of_origin := sanitize_text(p_country_of_origin, 'country_of_origin');
    p_description      := sanitize_text(p_description,      'description');

    -- [validate fk]
    perform validate_exists_by_id('brands',             p_brand_id);
    perform validate_exists_by_id('drive_types',        p_drive_type_id);
    perform validate_exists_by_id('transmission_types', p_transmission_type_id);
    perform validate_exists_by_id('usage_types',        p_usage_type_id);
    perform validate_exists_by_id('capacities',          p_capacity_id);

    insert into cars (
        name, price_of_origin, manufacture_date, country_of_origin, description,
        brand_id, drive_type_id, transmission_type_id, usage_type_id, capacity_id
    )
    values (
        p_name, p_price_of_origin, p_manufacture_date, p_country_of_origin, p_description,
        p_brand_id, p_drive_type_id, p_transmission_type_id, p_usage_type_id, p_capacity_id
    )
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_cars()
returns setof cars language plpgsql as $$
begin
    return query select * from cars where is_deleted = false;
exception when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_car_by_uuid(p_id uuid)
returns cars language plpgsql as $$
declare v_row cars;
begin
    select * into v_row from cars where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_car_by_uuid(
    p_id                   uuid,
    p_name                 varchar(100),
    p_price_of_origin      numeric(12, 2),
    p_manufacture_date     date,
    p_country_of_origin    varchar(100),
    p_description          text,
    p_brand_id             uuid,
    p_drive_type_id        uuid,
    p_transmission_type_id uuid,
    p_usage_type_id        uuid,
    p_capacity_id          uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name              := sanitize_text(p_name,              'name');
    p_country_of_origin := sanitize_text(p_country_of_origin, 'country_of_origin');
    p_description       := sanitize_text(p_description,       'description');

    perform validate_exists_by_id('brands',             p_brand_id);
    perform validate_exists_by_id('drive_types',        p_drive_type_id);
    perform validate_exists_by_id('transmission_types', p_transmission_type_id);
    perform validate_exists_by_id('usage_types',        p_usage_type_id);
    perform validate_exists_by_id('capacities',          p_capacity_id);

    update cars set
        name                 = p_name,
        price_of_origin      = p_price_of_origin,
        manufacture_date     = p_manufacture_date,
        country_of_origin    = p_country_of_origin,
        description          = p_description,
        brand_id             = p_brand_id,
        drive_type_id        = p_drive_type_id,
        transmission_type_id = p_transmission_type_id,
        usage_type_id        = p_usage_type_id,
        capacity_id          = p_capacity_id
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

-- -------------------------------
-- delete 1 (soft) / restore 1
-- -------------------------------
create or replace function delete_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('cars', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('cars', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_USER_PROFILE_CAR  (junction)
-- ============================================================
create table app_user_profile_cars (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,  -- [fix] добавлен is_deleted

    app_user_profile_id uuid    not null references app_user_profiles(id),
    car_id              uuid    not null references cars(id)
);

create index idx_app_user_profile_car_id_hash
    on app_user_profile_cars using hash (id);

create or replace function create_app_user_profile_car(
    p_app_user_profile_id uuid,
    p_car_id              uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);
    perform validate_exists_by_id('cars',              p_car_id);

    select id into v_id from app_user_profile_cars
    where app_user_profile_id = p_app_user_profile_id
      and car_id              = p_car_id
      and is_deleted          = true;

    if found then return set_entity_lifecycle('app_user_profile_cars', v_id, false); end if;

    insert into app_user_profile_cars (app_user_profile_id, car_id)
    values (p_app_user_profile_id, p_car_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_app_user_profile_cars()
returns setof app_user_profile_cars language plpgsql as $$
begin
    return query select * from app_user_profile_cars where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function get_app_user_profile_car_by_uuid(p_id uuid)
returns app_user_profile_cars language plpgsql as $$
declare v_row app_user_profile_cars;
begin
    select * into v_row from app_user_profile_cars where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function delete_app_user_profile_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_user_profile_cars', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_app_user_profile_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_user_profile_cars', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_BRAND  (junction)
-- ============================================================
create table profile_filter_brands (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references app_user_profiles(id),
    brand_id            uuid    not null references brands(id)
);

create index idx_profile_filter_brand_id_hash
    on profile_filter_brands using hash (id);

create or replace function create_profile_filter_brand(p_app_user_profile_id uuid, p_brand_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);
    perform validate_exists_by_id('brands',            p_brand_id);

    select id into v_id from profile_filter_brands
    where app_user_profile_id = p_app_user_profile_id and brand_id = p_brand_id and is_deleted = true;

    if found then return set_entity_lifecycle('profile_filter_brands', v_id, false); end if;

    insert into profile_filter_brands (app_user_profile_id, brand_id)
    values (p_app_user_profile_id, p_brand_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_profile_filter_brands()
returns setof profile_filter_brands language plpgsql as $$
begin return query select * from profile_filter_brands where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_profile_filter_brand_by_uuid(p_id uuid)
returns profile_filter_brands language plpgsql as $$
declare v_row profile_filter_brands;
begin
    select * into v_row from profile_filter_brands where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function delete_profile_filter_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_brands', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_profile_filter_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_brands', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_DRIVE_TYPE  (junction)
-- ============================================================
create table profile_filter_drive_types (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references app_user_profiles(id),
    drive_type_id       uuid    not null references drive_types(id)
);

create index idx_profile_filter_drive_type_id_hash
    on profile_filter_drive_types using hash (id);

create or replace function create_profile_filter_drive_type(p_app_user_profile_id uuid, p_drive_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);
    perform validate_exists_by_id('drive_types',       p_drive_type_id);

    select id into v_id from profile_filter_drive_types
    where app_user_profile_id = p_app_user_profile_id and drive_type_id = p_drive_type_id and is_deleted = true;

    if found then return set_entity_lifecycle('profile_filter_drive_types', v_id, false); end if;

    insert into profile_filter_drive_types (app_user_profile_id, drive_type_id)
    values (p_app_user_profile_id, p_drive_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_profile_filter_drive_types()
returns setof profile_filter_drive_types language plpgsql as $$
begin return query select * from profile_filter_drive_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_profile_filter_drive_type_by_uuid(p_id uuid)
returns profile_filter_drive_types language plpgsql as $$
declare v_row profile_filter_drive_types;
begin
    select * into v_row from profile_filter_drive_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function delete_profile_filter_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_drive_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_profile_filter_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_drive_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_TRANSMISSION_TYPE  (junction)
-- ============================================================
create table profile_filter_transmission_types (
    id                   uuid    primary key default uuidv7(),

    is_deleted           boolean not null default false,

    app_user_profile_id  uuid    not null references app_user_profiles(id),
    transmission_type_id uuid    not null references transmission_types(id)
);

create index idx_profile_filter_transmission_type_id_hash
    on profile_filter_transmission_types using hash (id);

create or replace function create_profile_filter_transmission_type(p_app_user_profile_id uuid, p_transmission_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles',  p_app_user_profile_id);
    perform validate_exists_by_id('transmission_types', p_transmission_type_id);

    select id into v_id from profile_filter_transmission_types
    where app_user_profile_id = p_app_user_profile_id and transmission_type_id = p_transmission_type_id and is_deleted = true;

    if found then return set_entity_lifecycle('profile_filter_transmission_types', v_id, false); end if;

    insert into profile_filter_transmission_types (app_user_profile_id, transmission_type_id)
    values (p_app_user_profile_id, p_transmission_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_profile_filter_transmission_types()
returns setof profile_filter_transmission_types language plpgsql as $$
begin return query select * from profile_filter_transmission_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_profile_filter_transmission_type_by_uuid(p_id uuid)
returns profile_filter_transmission_types language plpgsql as $$
declare v_row profile_filter_transmission_types;
begin
    select * into v_row from profile_filter_transmission_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function delete_profile_filter_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_transmission_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_profile_filter_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_transmission_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_USAGE_TYPE  (junction)
-- ============================================================
create table profile_filter_usage_types (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references app_user_profiles(id),
    usage_type_id       uuid    not null references usage_types(id)
);

create index idx_profile_filter_usage_type_id_hash
    on profile_filter_usage_types using hash (id);

create or replace function create_profile_filter_usage_type(p_app_user_profile_id uuid, p_usage_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);
    perform validate_exists_by_id('usage_types',       p_usage_type_id);

    select id into v_id from profile_filter_usage_types
    where app_user_profile_id = p_app_user_profile_id and usage_type_id = p_usage_type_id and is_deleted = true;

    if found then return set_entity_lifecycle('profile_filter_usage_types', v_id, false); end if;

    insert into profile_filter_usage_types (app_user_profile_id, usage_type_id)
    values (p_app_user_profile_id, p_usage_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_profile_filter_usage_types()
returns setof profile_filter_usage_types language plpgsql as $$
begin return query select * from profile_filter_usage_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_profile_filter_usage_type_by_uuid(p_id uuid)
returns profile_filter_usage_types language plpgsql as $$
declare v_row profile_filter_usage_types;
begin
    select * into v_row from profile_filter_usage_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function delete_profile_filter_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_usage_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_profile_filter_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_usage_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_CAPACITY  (junction)
-- ============================================================
create table profile_filter_capacities (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references app_user_profiles(id),
    capacity_id         uuid    not null references capacities(id)
);

create index idx_profile_filter_capacity_id_hash
    on profile_filter_capacities using hash (id);

create or replace function create_profile_filter_capacity(p_app_user_profile_id uuid, p_capacity_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_user_profiles', p_app_user_profile_id);
    perform validate_exists_by_id('capacities',         p_capacity_id);

    select id into v_id from profile_filter_capacities
    where app_user_profile_id = p_app_user_profile_id and capacity_id = p_capacity_id and is_deleted = true;

    if found then return set_entity_lifecycle('profile_filter_capacities', v_id, false); end if;

    insert into profile_filter_capacities (app_user_profile_id, capacity_id)
    values (p_app_user_profile_id, p_capacity_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_profile_filter_capacities()
returns setof profile_filter_capacities language plpgsql as $$
begin return query select * from profile_filter_capacities where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_profile_filter_capacity_by_uuid(p_id uuid)
returns profile_filter_capacities language plpgsql as $$
declare v_row profile_filter_capacities;
begin
    select * into v_row from profile_filter_capacities where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function delete_profile_filter_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_capacities', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_profile_filter_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('profile_filter_capacities', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_REQUEST
-- ============================================================
create table app_requests (
    id          uuid    primary key default uuidv7(),

    comment     text,
    is_deleted  boolean not null default false,

    app_user_id uuid    not null references app_users(id),
    car_id      uuid    not null references cars(id)
);

create index idx_app_request_id_hash
    on app_requests using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_app_request(
    p_app_user_id uuid,
    p_car_id      uuid,
    p_comment     text default null
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [validate fk]
    perform validate_exists_by_id('app_users', p_app_user_id);
    perform validate_exists_by_id('cars',      p_car_id);

    -- [sanitize] comment опциональный — sanitize только если передан
    if p_comment is not null then
        p_comment := sanitize_text(p_comment, 'comment');
    end if;

    insert into app_requests (app_user_id, car_id, comment)
    values (p_app_user_id, p_car_id, p_comment)
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_app_requests()
returns setof app_requests language plpgsql as $$
begin return query select * from app_requests where is_deleted = false;
exception when others then return; end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_app_request_by_uuid(p_id uuid)
returns app_requests language plpgsql as $$
declare v_row app_requests;
begin
    select * into v_row from app_requests where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_app_request_by_uuid(
    p_id          uuid,
    p_app_user_id uuid,
    p_car_id      uuid,
    p_comment     text default null
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_users', p_app_user_id);
    perform validate_exists_by_id('cars',      p_car_id);

    if p_comment is not null then
        p_comment := sanitize_text(p_comment, 'comment');
    end if;

    update app_requests
    set app_user_id = p_app_user_id,
        car_id      = p_car_id,
        comment     = p_comment
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception when others then return null; end;
$$;

-- -------------------------------
-- delete 1 (soft) / restore 1
-- -------------------------------
create or replace function delete_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_requests', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_requests', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_ORDER
-- ============================================================
create table app_orders (
    id              uuid           primary key default uuidv7(),

    comment         text,
    order_date      date           not null,
    period_months   int            not null check (period_months > 0),
    down_payment    numeric(12, 2) not null check (down_payment > 0),
    monthly_payment numeric(12, 2) not null check (monthly_payment > 0),
    is_deleted      boolean        not null default false,

    app_user_id     uuid           not null references app_users(id),
    manager_id      uuid           not null references app_users(id),
    app_request_id  uuid           not null references app_requests(id)
);

create index idx_app_order_id_hash
    on app_orders using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function create_app_order(
    p_order_date      date,
    p_period_months   int,
    p_down_payment    numeric(12, 2),
    p_monthly_payment numeric(12, 2),
    p_app_user_id     uuid,
    p_manager_id      uuid,
    p_app_request_id  uuid,
    p_comment         text default null
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [validate fk]
    perform validate_exists_by_id('app_users',    p_app_user_id);
    perform validate_exists_by_id('app_users',    p_manager_id);
    perform validate_exists_by_id('app_requests', p_app_request_id);

    if p_comment is not null then
        p_comment := sanitize_text(p_comment, 'comment');
    end if;

    insert into app_orders (
        order_date, period_months, down_payment, monthly_payment,
        app_user_id, manager_id, app_request_id, comment
    )
    values (
        p_order_date, p_period_months, p_down_payment, p_monthly_payment,
        p_app_user_id, p_manager_id, p_app_request_id, p_comment
    )
    returning id into v_id;

    return v_id;
exception
    when others then
        return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function get_app_orders()
returns setof app_orders language plpgsql as $$
begin return query select * from app_orders where is_deleted = false;
exception when others then return; end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function get_app_order_by_uuid(p_id uuid)
returns app_orders language plpgsql as $$
declare v_row app_orders;
begin
    select * into v_row from app_orders where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function update_app_order_by_uuid(
    p_id              uuid,
    p_order_date      date,
    p_period_months   int,
    p_down_payment    numeric(12, 2),
    p_monthly_payment numeric(12, 2),
    p_app_user_id     uuid,
    p_manager_id      uuid,
    p_app_request_id  uuid,
    p_comment         text default null
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_users',    p_app_user_id);
    perform validate_exists_by_id('app_users',    p_manager_id);
    perform validate_exists_by_id('app_requests', p_app_request_id);

    if p_comment is not null then
        p_comment := sanitize_text(p_comment, 'comment');
    end if;

    update app_orders set
        order_date      = p_order_date,
        period_months   = p_period_months,
        down_payment    = p_down_payment,
        monthly_payment = p_monthly_payment,
        app_user_id     = p_app_user_id,
        manager_id      = p_manager_id,
        app_request_id  = p_app_request_id,
        comment         = p_comment
    where id = p_id and is_deleted = false
    returning id into v_id;

    return v_id;
exception when others then return null; end;
$$;

-- -------------------------------
-- delete 1 (soft) / restore 1
-- -------------------------------
create or replace function delete_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_orders', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_orders', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_STATUS
-- ============================================================
-- [note] допустимые значения name:
--        'REQUEST_PENDING', 'REQUEST_ACCEPTED', 'REQUEST_CANCELLED',
--        'ORDER_PENDING',   'ORDER_ACCEPTED',   'ORDER_CANCELLED'
create table app_statuses (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_app_status_id_hash
    on app_statuses using hash (id);

create or replace function create_app_status(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    select id into v_id from app_statuses where name = p_name and is_deleted = true;
    if found then return set_entity_lifecycle('app_statuses', v_id, false); end if;
    insert into app_statuses (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_app_statuses()
returns setof app_statuses language plpgsql as $$
begin return query select * from app_statuses where is_deleted = false;
exception when others then return; end;
$$;

create or replace function get_app_status_by_uuid(p_id uuid)
returns app_statuses language plpgsql as $$
declare v_row app_statuses;
begin
    select * into v_row from app_statuses where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function update_app_status_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := sanitize_text(p_name, 'name');
    update app_statuses set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null; end;
$$;

create or replace function delete_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_statuses', p_id, true);
exception when others then return null; end;
$$;

create or replace function restore_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return set_entity_lifecycle('app_statuses', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_REQUEST_STATUS_HISTORY
-- ============================================================
-- [note] история — только append, физического удаления нет,
--        is_deleted добавлен для единообразия схемы.
create table app_request_status_histories (
    id             uuid        primary key default uuidv7(),

    created_at     timestamptz not null default now(),
    is_deleted     boolean     not null default false,

    app_status_id  uuid        not null references app_statuses(id),
    app_request_id uuid        not null references app_requests(id)
);

create index idx_app_request_status_history_id_hash
    on app_request_status_histories using hash (id);

create or replace function create_app_request_status_history(
    p_app_status_id  uuid,
    p_app_request_id uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_statuses',  p_app_status_id);
    perform validate_exists_by_id('app_requests', p_app_request_id);

    insert into app_request_status_histories (app_status_id, app_request_id)
    values (p_app_status_id, p_app_request_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_app_request_status_histories()
returns setof app_request_status_histories language plpgsql as $$
begin
    return query
    select * from app_request_status_histories
    where is_deleted = false
    order by created_at desc;
exception when others then return; end;
$$;

create or replace function get_app_request_status_history_by_uuid(p_id uuid)
returns app_request_status_histories language plpgsql as $$
declare v_row app_request_status_histories;
begin
    select * into v_row from app_request_status_histories where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;


-- ============================================================
-- APP_ORDER_STATUS_HISTORY
-- ============================================================
create table app_order_status_histories (
    id            uuid        primary key default uuidv7(),

    created_at    timestamptz not null default now(),
    is_deleted    boolean     not null default false,

    app_status_id uuid        not null references app_statuses(id),
    app_order_id  uuid        not null references app_orders(id)
);

create index idx_app_order_status_history_id_hash
    on app_order_status_histories using hash (id);

create or replace function create_app_order_status_history(
    p_app_status_id uuid,
    p_app_order_id  uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform validate_exists_by_id('app_statuses', p_app_status_id);
    perform validate_exists_by_id('app_orders',  p_app_order_id);

    insert into app_order_status_histories (app_status_id, app_order_id)
    values (p_app_status_id, p_app_order_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function get_app_order_status_histories()
returns setof app_order_status_histories language plpgsql as $$
begin
    return query
    select * from app_order_status_histories
    where is_deleted = false
    order by created_at desc;
exception when others then return; end;
$$;

create or replace function get_app_order_status_history_by_uuid(p_id uuid)
returns app_order_status_histories language plpgsql as $$
declare v_row app_order_status_histories;
begin
    select * into v_row from app_order_status_histories where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;


-- ============================================================
-- warn: drop roles in reverse dependency order
-- ============================================================
-- drop owned by role_guest;
-- drop role if exists role_guest;
-- drop owned by role_user;
-- drop role if exists role_user;
-- drop owned by role_manager;
-- drop role if exists role_manager;
-- drop owned by role_admin;
-- drop role if exists role_admin;


-- ============================================================
-- ROLES
-- ============================================================
create role role_guest   nologin;
create role role_user    nologin;
create role role_manager nologin;
create role role_admin   nologin;


-- ============================================================
-- GRANT EXECUTE на util-функции
-- все роли могут вызывать utils через CRUD-функции
-- ============================================================
grant execute on function sanitize_text(text, text)                 to role_guest, role_user, role_manager, role_admin;
grant execute on function is_record_active(text, uuid)              to role_guest, role_user, role_manager, role_admin;
grant execute on function validate_exists_by_id(text, uuid)         to role_guest, role_user, role_manager, role_admin;
grant execute on function set_entity_lifecycle(text, uuid, boolean) to role_user, role_manager, role_admin;


-- ============================================================
-- GRANT EXECUTE на CRUD-функции
-- ============================================================

-- -------------------------------
-- app_roles
-- admin: R C U D
-- -------------------------------
grant execute on function get_app_roles()                        to role_admin;
grant execute on function get_app_role_by_uuid(uuid)             to role_admin;
grant execute on function create_app_role(varchar)               to role_admin;
grant execute on function update_app_role_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_app_role_by_uuid(uuid)          to role_admin;
grant execute on function restore_app_role_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- app_user_profiles
-- user:    R C U own
-- manager: R C U own
-- admin:   R C U D
-- [note] own реализуется через RLS — см. ниже
-- -------------------------------
grant execute on function get_app_user_profiles()                              to role_user, role_manager, role_admin;
grant execute on function get_app_user_profile_by_uuid(uuid)                   to role_user, role_manager, role_admin;
grant execute on function create_app_user_profile(varchar, uuid)               to role_user, role_manager, role_admin;
grant execute on function update_app_user_profile_by_uuid(uuid, varchar, uuid) to role_user, role_manager, role_admin;
grant execute on function delete_app_user_profile_by_uuid(uuid)                to role_admin;
grant execute on function restore_app_user_profile_by_uuid(uuid)               to role_admin;

-- -------------------------------
-- app_users
-- user:    R C U own
-- manager: R C U own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_app_users()                                       to role_user, role_manager, role_admin;
grant execute on function get_app_user_by_uuid(uuid)                            to role_user, role_manager, role_admin;
grant execute on function create_app_user(varchar, varchar, uuid)               to role_user, role_manager, role_admin;
grant execute on function update_app_user_by_uuid(uuid, varchar, varchar, uuid) to role_user, role_manager, role_admin;
grant execute on function delete_app_user_by_uuid(uuid)                         to role_admin;
grant execute on function restore_app_user_by_uuid(uuid)                        to role_admin;

-- -------------------------------
-- brands
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_brands()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function get_brand_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function create_brand(varchar)               to role_admin;
grant execute on function update_brand_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_brand_by_uuid(uuid)          to role_admin;
grant execute on function restore_brand_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- drive_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_drive_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function get_drive_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function create_drive_type(varchar)               to role_admin;
grant execute on function update_drive_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_drive_type_by_uuid(uuid)          to role_admin;
grant execute on function restore_drive_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- transmission_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_transmission_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function get_transmission_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function create_transmission_type(varchar)               to role_admin;
grant execute on function update_transmission_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_transmission_type_by_uuid(uuid)          to role_admin;
grant execute on function restore_transmission_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- usage_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_usage_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function get_usage_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function create_usage_type(varchar)               to role_admin;
grant execute on function update_usage_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_usage_type_by_uuid(uuid)          to role_admin;
grant execute on function restore_usage_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- capacity_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_capacity_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function get_capacity_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function create_capacity_type(varchar)               to role_admin;
grant execute on function update_capacity_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_capacity_type_by_uuid(uuid)          to role_admin;
grant execute on function restore_capacity_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- capacities
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_capacities()                         to role_guest, role_user, role_manager, role_admin;
grant execute on function get_capacity_by_uuid(uuid)               to role_guest, role_user, role_manager, role_admin;
grant execute on function create_capacity(int, uuid)               to role_admin;
grant execute on function update_capacity_by_uuid(uuid, int, uuid) to role_admin;
grant execute on function delete_capacity_by_uuid(uuid)            to role_admin;
grant execute on function restore_capacity_by_uuid(uuid)           to role_admin;

-- -------------------------------
-- cars
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function get_cars()                                                                                    to role_guest, role_user, role_manager, role_admin;
grant execute on function get_car_by_uuid(uuid)                                                                         to role_guest, role_user, role_manager, role_admin;
grant execute on function create_car(varchar, numeric, date, varchar, text, uuid, uuid, uuid, uuid, uuid)               to role_admin;
grant execute on function update_car_by_uuid(uuid, varchar, numeric, date, varchar, text, uuid, uuid, uuid, uuid, uuid) to role_admin;
grant execute on function delete_car_by_uuid(uuid)                                                                      to role_admin;
grant execute on function restore_car_by_uuid(uuid)                                                                     to role_admin;

-- -------------------------------
-- app_user_profile_cars
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_app_user_profile_cars()                to role_user, role_manager, role_admin;
grant execute on function get_app_user_profile_car_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_app_user_profile_car(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_app_user_profile_car_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_app_user_profile_car_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- profile_filter_brands
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_profile_filter_brands()                to role_user, role_manager, role_admin;
grant execute on function get_profile_filter_brand_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_profile_filter_brand(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_profile_filter_brand_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_profile_filter_brand_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- profile_filter_drive_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_profile_filter_drive_types()                to role_user, role_manager, role_admin;
grant execute on function get_profile_filter_drive_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_profile_filter_drive_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_profile_filter_drive_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_profile_filter_drive_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- profile_filter_transmission_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_profile_filter_transmission_types()                to role_user, role_manager, role_admin;
grant execute on function get_profile_filter_transmission_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_profile_filter_transmission_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_profile_filter_transmission_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_profile_filter_transmission_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- profile_filter_usage_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_profile_filter_usage_types()                to role_user, role_manager, role_admin;
grant execute on function get_profile_filter_usage_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_profile_filter_usage_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_profile_filter_usage_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_profile_filter_usage_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- profile_filter_capacities
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function get_profile_filter_capacities()               to role_user, role_manager, role_admin;
grant execute on function get_profile_filter_capacity_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function create_profile_filter_capacity(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function delete_profile_filter_capacity_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function restore_profile_filter_capacity_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- app_requests
-- user:    R C own
-- manager: R all C U D
-- admin:   R C U D
-- -------------------------------
grant execute on function get_app_requests()                                 to role_user, role_manager, role_admin;
grant execute on function get_app_request_by_uuid(uuid)                      to role_user, role_manager, role_admin;
grant execute on function create_app_request(uuid, uuid, text)               to role_user, role_manager, role_admin;
grant execute on function update_app_request_by_uuid(uuid, uuid, uuid, text) to role_manager, role_admin;
grant execute on function delete_app_request_by_uuid(uuid)                   to role_manager, role_admin;
grant execute on function restore_app_request_by_uuid(uuid)                  to role_manager, role_admin;

-- -------------------------------
-- app_orders
-- user:    R own
-- manager: R all C U
-- admin:   R C U D
-- -------------------------------
grant execute on function get_app_orders()                                                                    to role_user, role_manager, role_admin;
grant execute on function get_app_order_by_uuid(uuid)                                                         to role_user, role_manager, role_admin;
grant execute on function create_app_order(date, int, numeric, numeric, uuid, uuid, uuid, text)               to role_manager, role_admin;
grant execute on function update_app_order_by_uuid(uuid, date, int, numeric, numeric, uuid, uuid, uuid, text) to role_manager, role_admin;
grant execute on function delete_app_order_by_uuid(uuid)                                                      to role_admin;
grant execute on function restore_app_order_by_uuid(uuid)                                                     to role_admin;


-- -------------------------------
-- app_statuses
-- manager: R
-- admin:   R C U D
-- -------------------------------
grant execute on function get_app_statuses()                       to role_manager, role_admin;
grant execute on function get_app_status_by_uuid(uuid)             to role_manager, role_admin;
grant execute on function create_app_status(varchar)               to role_admin;
grant execute on function update_app_status_by_uuid(uuid, varchar) to role_admin;
grant execute on function delete_app_status_by_uuid(uuid)          to role_admin;
grant execute on function restore_app_status_by_uuid(uuid)         to role_admin;


-- -------------------------------
-- app_request_status_histories
-- user:    R own
-- manager: R all C
-- admin:   R C
-- [note] append-only — delete/restore нет ни у кого
-- -------------------------------
grant execute on function get_app_request_status_histories()            to role_user, role_manager, role_admin;
grant execute on function get_app_request_status_history_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function create_app_request_status_history(uuid, uuid) to role_manager, role_admin;


-- -------------------------------
-- app_order_status_histories
-- user:    R own
-- manager: R all C
-- admin:   R C
-- [note] append-only — delete/restore нет ни у кого
-- -------------------------------
grant execute on function get_app_order_status_histories()            to role_user, role_manager, role_admin;
grant execute on function get_app_order_status_history_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function create_app_order_status_history(uuid, uuid) to role_manager, role_admin;



-- ============================================================
-- TABLE-LEVEL GRANT
-- ============================================================


-- -------------------------------
-- SELECT — все таблицы
-- нужен для get*, is_record_active, validate_exists_by_id
-- -------------------------------
grant select on
    app_roles,
    app_user_profiles,
    app_users,
    brands,
    drive_types,
    transmission_types,
    usage_types,
    capacity_types,
    capacities,
    cars,
    app_user_profile_cars,
    profile_filter_brands,
    profile_filter_drive_types,
    profile_filter_transmission_types,
    profile_filter_usage_types,
    profile_filter_capacities,
    app_requests,
    app_orders,
    app_statuses,
    app_request_status_histories,
    app_order_status_histories
to role_guest, role_user, role_manager, role_admin;


-- -------------------------------
-- INSERT — все таблицы
-- нужен для create_*
-- -------------------------------
grant insert on
    app_roles,
    app_user_profiles,
    app_users,
    brands,
    drive_types,
    transmission_types,
    usage_types,
    capacity_types,
    capacities,
    cars,
    app_user_profile_cars,
    profile_filter_brands,
    profile_filter_drive_types,
    profile_filter_transmission_types,
    profile_filter_usage_types,
    profile_filter_capacities,
    app_requests,
    app_orders,
    app_statuses,
    app_request_status_histories,
    app_order_status_histories
to role_user, role_manager, role_admin;


-- -------------------------------
-- UPDATE — не-history таблицы
-- нужен для update_*, delete_* soft, restore_*
-- history — только append, update не нужен
-- -------------------------------
grant update on
    app_roles,
    app_user_profiles,
    app_users,
    brands,
    drive_types,
    transmission_types,
    usage_types,
    capacity_types,
    capacities,
    cars,
    app_user_profile_cars,
    profile_filter_brands,
    profile_filter_drive_types,
    profile_filter_transmission_types,
    profile_filter_usage_types,
    profile_filter_capacities,
    app_requests,
    app_orders,
    app_statuses
to role_user, role_manager, role_admin;