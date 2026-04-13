-- ============================================================
-- SCHEMAS
-- ============================================================
create schema if not exists app;
create schema if not exists profile;
create schema if not exists content;
create schema if not exists junction;
create schema if not exists util;
create schema if not exists audit;


-- ============================================================
-- warn: drop functions before tables
-- ============================================================
-- drop function if exists util.set_entity_lifecycle(text, uuid, boolean);
-- drop function if exists util.validate_exists_by_id(text, uuid);
-- drop function if exists util.is_record_active(text, uuid);
-- drop function if exists util.sanitize_text(text, text);


-- ============================================================
-- warn: drop tables in reverse dependency order
-- ============================================================
-- drop table if exists content.order_status_histories cascade;
-- drop table if exists content.request_status_histories cascade;
-- drop table if exists content.statuses cascade;

-- drop table if exists content.orders cascade;
-- drop table if exists content.requests cascade;

-- drop table if exists junction.profile_filter_brands cascade;
-- drop table if exists junction.profile_filter_drive_types cascade;
-- drop table if exists junction.profile_filter_transmission_types cascade;
-- drop table if exists junction.profile_filter_usage_types cascade;
-- drop table if exists junction.profile_filter_capacities cascade;

-- drop table if exists junction.user_profile_cars cascade;
-- drop table if exists content.cars cascade;

-- drop table if exists content.capacities cascade;
-- drop table if exists content.capacity_types cascade;
-- drop table if exists content.drive_types cascade;
-- drop table if exists content.transmission_types cascade;
-- drop table if exists content.usage_types cascade;
-- drop table if exists content.brands cascade;

-- drop table if exists app.users cascade;
-- drop table if exists profile.user_profiles cascade;
-- drop table if exists app.roles cascade;


-- ============================================================
-- UTILS
-- ============================================================


create or replace function util.sanitize_text(
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


create or replace function util.is_record_active(
    p_table_name text,   -- формат: 'schema.table' или просто 'table'
    p_id         uuid
)
returns boolean
language plpgsql
as $$
declare
    v_exists      boolean;
    v_has_deleted boolean;
    v_schema      text;
    v_table       text;
    v_parts       text[];
begin
    -- [note] разбираем 'schema.table' или просто 'table'
    v_parts := string_to_array(p_table_name, '.');
    if array_length(v_parts, 1) = 2 then
        v_schema := v_parts[1];
        v_table  := v_parts[2];
    else
        v_schema := current_schema();
        v_table  := v_parts[1];
    end if;

    select exists(
        select 1
        from information_schema.columns
        where table_schema = v_schema
          and table_name   = v_table
          and column_name  = 'is_deleted'
    ) into v_has_deleted;

    if v_has_deleted then
        execute format(
            'select exists(select 1 from %I.%I where id = $1 and is_deleted = false)',
            v_schema, v_table
        )
        into v_exists
        using p_id;
    else
        execute format(
            'select exists(select 1 from %I.%I where id = $1)',
            v_schema, v_table
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


create or replace function util.validate_exists_by_id(
    p_table_name text,
    p_id         uuid
)
returns void
language plpgsql
as $$
begin
    if not util.is_record_active(p_table_name, p_id) then
        raise exception
            'validate_exists_by_id: record not found or deleted in %.id = %',
            p_table_name, p_id;
    end if;
end;
$$;


create or replace function util.set_entity_lifecycle(
    p_table_name text,   -- формат: 'schema.table' или просто 'table'
    p_id         uuid,
    p_is_deleted boolean
)
returns uuid
language plpgsql
as $$
declare
    v_id     uuid;
    v_schema text;
    v_table  text;
    v_parts  text[];
begin
    -- [note] разбираем 'schema.table' или просто 'table'
    v_parts := string_to_array(p_table_name, '.');
    if array_length(v_parts, 1) = 2 then
        v_schema := v_parts[1];
        v_table  := v_parts[2];
    else
        v_schema := current_schema();
        v_table  := v_parts[1];
    end if;

    execute format(
        'update %I.%I set is_deleted = $1 where id = $2 returning id',
        v_schema, v_table
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
create table app.roles (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_app_role_id_hash
    on app.roles using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function app.create_app_role(
    p_name varchar(100)
)
returns uuid
language plpgsql
as $$
declare
    v_id uuid;
begin
    -- [sanitize]
    p_name := util.sanitize_text(p_name, 'name');

    -- [note] если запись с таким name уже есть но soft-deleted → восстанавливаем
    select id into v_id
    from app.roles
    where name = p_name and is_deleted = true;

    if found then
        return util.set_entity_lifecycle('app.roles', v_id, false);
    end if;

    insert into app.roles (name)
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
create or replace function app.get_app_roles()
returns setof app.roles
language plpgsql
as $$
begin
    return query
    select * from app.roles
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function app.get_app_role_by_uuid(
    p_id uuid
)
returns app.roles
language plpgsql
as $$
declare
    v_row app.roles;
begin
    select * into v_row
    from app.roles
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
create or replace function app.update_app_role_by_uuid(
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
    p_name := util.sanitize_text(p_name, 'name');

    update app.roles
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
create or replace function app.delete_app_role_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('app.roles', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function app.restore_app_role_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('app.roles', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- APP_USER_PROFILE
-- ============================================================
create table profile.user_profiles (
    id          uuid         primary key default uuidv7(),

    name        varchar(100) not null,
    is_deleted  boolean      not null default false,

    app_role_id uuid         not null references app.roles(id)
);

create index idx_app_user_profile_id_hash
    on profile.user_profiles using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function profile.create_app_user_profile(
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
    p_name := util.sanitize_text(p_name, 'name');

    -- [validate fk] бросит exception если app.roles не существует или удалён
    perform util.validate_exists_by_id('app.roles', p_app_role_id);

    -- [note] если профиль с таким name удалён → восстанавливаем и обновляем роль
    select id into v_id
    from profile.user_profiles
    where name = p_name and is_deleted = true;

    if found then
        update profile.user_profiles
        set is_deleted  = false,
            app_role_id = p_app_role_id
        where id = v_id
        returning id into v_id;

        return v_id;
    end if;

    -- [fix] values (p_name, select id from ...) — невалидный синтаксис.
    --       FK-ограничение на таблице гарантирует целостность,
    --       validate_exists_by_id уже проверил существование выше.
    insert into profile.user_profiles (name, app_role_id)
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
create or replace function profile.get_app_user_profiles()
returns setof profile.user_profiles
language plpgsql
as $$
begin
    return query
    select * from profile.user_profiles
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function profile.get_app_user_profile_by_uuid(
    p_id uuid
)
returns profile.user_profiles
language plpgsql
as $$
declare
    v_row profile.user_profiles;
begin
    select * into v_row
    from profile.user_profiles
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
create or replace function profile.update_app_user_profile_by_uuid(
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
    p_name := util.sanitize_text(p_name, 'name');

    -- [validate fk]
    perform util.validate_exists_by_id('app.roles', p_app_role_id);

    update profile.user_profiles
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
create or replace function profile.delete_app_user_profile_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('profile.user_profiles', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function profile.restore_app_user_profile_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('profile.user_profiles', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- APP_USER
-- ============================================================
create table app.users (
    id                  uuid         primary key default uuidv7(),

    email               varchar(250) unique not null,
    password            varchar(128) not null,
    is_deleted          boolean      not null default false,

    app_user_profile_id uuid         not null references profile.user_profiles(id)
);

create index idx_app_user_id_hash
    on app.users using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function app.create_app_user(
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
    p_email := util.sanitize_text(p_email, 'email');

    -- [validate fk]
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);

    -- [note] email уже есть но soft-deleted → восстанавливаем
    select id into v_id
    from app.users
    where email = p_email and is_deleted = true;

    if found then
        update app.users
        set is_deleted          = false,
            password            = p_password,
            app_user_profile_id = p_app_user_profile_id
        where id = v_id
        returning id into v_id;

        return v_id;
    end if;

    insert into app.users (email, password, app_user_profile_id)
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
create or replace function app.get_app_users()
returns setof app.users
language plpgsql
as $$
begin
    return query
    select * from app.users
    where is_deleted = false;
exception
    when others then
        return;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function app.get_app_user_by_uuid(
    p_id uuid
)
returns app.users
language plpgsql
as $$
declare
    v_row app.users;
begin
    select * into v_row
    from app.users
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
create or replace function app.update_app_user_by_uuid(
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
    p_email := util.sanitize_text(p_email, 'email');

    -- [validate fk]
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);

    update app.users
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
create or replace function app.delete_app_user_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('app.users', p_id, true);
exception
    when others then
        return null;
end;
$$;


-- -------------------------------
-- restore 1
-- -------------------------------
create or replace function app.restore_app_user_by_uuid(
    p_id uuid
)
returns uuid
language plpgsql
as $$
begin
    return util.set_entity_lifecycle('app.users', p_id, false);
exception
    when others then
        return null;
end;
$$;


-- ============================================================
-- BRAND
-- ============================================================
create table content.brands (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_brand_id_hash
    on content.brands using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function content.create_brand(p_name varchar(100))
returns uuid language plpgsql as $$
declare
    v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');

    select id into v_id from content.brands
    where name = p_name and is_deleted = true;

    if found then
        return util.set_entity_lifecycle('content.brands', v_id, false);
    end if;

    insert into content.brands (name) values (p_name) returning id into v_id;
    return v_id;
exception
    when others then return null;
end;
$$;

-- -------------------------------
-- get many
-- -------------------------------
create or replace function content.get_brands()
returns setof content.brands language plpgsql as $$
begin
    return query select * from content.brands where is_deleted = false;
exception
    when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_brand_by_uuid(p_id uuid)
returns content.brands language plpgsql as $$
declare
    v_row content.brands;
begin
    select * into v_row from content.brands where id = p_id and is_deleted = false;
    return v_row;
exception
    when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function content.update_brand_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare
    v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.brands set name = p_name
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
create or replace function content.delete_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.brands', p_id, true);
exception
    when others then return null;
end;
$$;

create or replace function content.restore_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.brands', p_id, false);
exception
    when others then return null;
end;
$$;


-- ============================================================
-- DRIVE_TYPE
-- ============================================================
create table content.drive_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_drive_type_id_hash
    on content.drive_types using hash (id);

create or replace function content.create_drive_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.drive_types where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.drive_types', v_id, false); end if;
    insert into content.drive_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_drive_types()
returns setof content.drive_types language plpgsql as $$
begin
    return query select * from content.drive_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function content.get_drive_type_by_uuid(p_id uuid)
returns content.drive_types language plpgsql as $$
declare v_row content.drive_types;
begin
    select * into v_row from content.drive_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function content.update_drive_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.drive_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.delete_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.drive_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.drive_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- TRANSMISSION_TYPE
-- ============================================================
create table content.transmission_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_transmission_type_id_hash
    on content.transmission_types using hash (id);

create or replace function content.create_transmission_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.transmission_types where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.transmission_types', v_id, false); end if;
    insert into content.transmission_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_transmission_types()
returns setof content.transmission_types language plpgsql as $$
begin
    return query select * from content.transmission_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function content.get_transmission_type_by_uuid(p_id uuid)
returns content.transmission_types language plpgsql as $$
declare v_row content.transmission_types;
begin
    select * into v_row from content.transmission_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function content.update_transmission_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.transmission_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.delete_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.transmission_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.transmission_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- USAGE_TYPE
-- ============================================================
create table content.usage_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_usage_type_id_hash
    on content.usage_types using hash (id);

create or replace function content.create_usage_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.usage_types where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.usage_types', v_id, false); end if;
    insert into content.usage_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_usage_types()
returns setof content.usage_types language plpgsql as $$
begin
    return query select * from content.usage_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function content.get_usage_type_by_uuid(p_id uuid)
returns content.usage_types language plpgsql as $$
declare v_row content.usage_types;
begin
    select * into v_row from content.usage_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function content.update_usage_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.usage_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.delete_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.usage_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.usage_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAPACITY_TYPE
-- ============================================================
create table content.capacity_types (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_capacity_type_id_hash
    on content.capacity_types using hash (id);

create or replace function content.create_capacity_type(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.capacity_types where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.capacity_types', v_id, false); end if;
    insert into content.capacity_types (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_capacity_types()
returns setof content.capacity_types language plpgsql as $$
begin
    return query select * from content.capacity_types where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function content.get_capacity_type_by_uuid(p_id uuid)
returns content.capacity_types language plpgsql as $$
declare v_row content.capacity_types;
begin
    select * into v_row from content.capacity_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function content.update_capacity_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.capacity_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.delete_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.capacity_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.capacity_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAPACITY
-- ============================================================
create table content.capacities (
    id               uuid    primary key default uuidv7(),

    value            int     not null check (value > 0),
    is_deleted       boolean not null default false,

    capacity_type_id uuid    not null references content.capacity_types(id)
);

create index idx_capacity_id_hash
    on content.capacities using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function content.create_capacity(
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
    perform util.validate_exists_by_id('content.capacity_types', p_capacity_type_id);

    -- [note] та же пара value+capacity_type_id удалена → восстанавливаем
    select id into v_id
    from content.capacities
    where value = p_value
      and capacity_type_id = p_capacity_type_id
      and is_deleted = true;

    if found then
        return util.set_entity_lifecycle('content.capacities', v_id, false);
    end if;

    insert into content.capacities (value, capacity_type_id)
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
create or replace function content.get_capacities()
returns setof content.capacities language plpgsql as $$
begin
    return query select * from content.capacities where is_deleted = false;
exception when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_capacity_by_uuid(p_id uuid)
returns content.capacities language plpgsql as $$
declare v_row content.capacities;
begin
    select * into v_row from content.capacities where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function content.update_capacity_by_uuid(
    p_id               uuid,
    p_value            int,
    p_capacity_type_id uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('content.capacity_types', p_capacity_type_id);
    update content.capacities
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
create or replace function content.delete_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.capacities', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.capacities', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- CAR
-- ============================================================
create table content.cars (
    id                   uuid           primary key default uuidv7(),

    name                 varchar(100)   not null,
    price_of_origin      numeric(12, 2) not null check (price_of_origin > 0),
    manufacture_date     date           not null,
    country_of_origin    varchar(100)   not null,
    description          text           not null,
    is_deleted           boolean        not null default false,

    brand_id             uuid           not null references content.brands(id),
    drive_type_id        uuid           not null references content.drive_types(id),
    transmission_type_id uuid           not null references content.transmission_types(id),
    usage_type_id        uuid           not null references content.usage_types(id),
    capacity_id          uuid           not null references content.capacities(id)
);

create index idx_car_id_hash
    on content.cars using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function content.create_car(
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
    p_name             := util.sanitize_text(p_name,             'name');
    p_country_of_origin := util.sanitize_text(p_country_of_origin, 'country_of_origin');
    p_description      := util.sanitize_text(p_description,      'description');

    -- [validate fk]
    perform util.validate_exists_by_id('content.brands',             p_brand_id);
    perform util.validate_exists_by_id('content.drive_types',        p_drive_type_id);
    perform util.validate_exists_by_id('content.transmission_types', p_transmission_type_id);
    perform util.validate_exists_by_id('content.usage_types',        p_usage_type_id);
    perform util.validate_exists_by_id('content.capacities',          p_capacity_id);

    insert into content.cars (
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
create or replace function content.get_cars()
returns setof content.cars language plpgsql as $$
begin
    return query select * from content.cars where is_deleted = false;
exception when others then return;
end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_car_by_uuid(p_id uuid)
returns content.cars language plpgsql as $$
declare v_row content.cars;
begin
    select * into v_row from content.cars where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function content.update_car_by_uuid(
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
    p_name              := util.sanitize_text(p_name,              'name');
    p_country_of_origin := util.sanitize_text(p_country_of_origin, 'country_of_origin');
    p_description       := util.sanitize_text(p_description,       'description');

    perform util.validate_exists_by_id('content.brands',             p_brand_id);
    perform util.validate_exists_by_id('content.drive_types',        p_drive_type_id);
    perform util.validate_exists_by_id('content.transmission_types', p_transmission_type_id);
    perform util.validate_exists_by_id('content.usage_types',        p_usage_type_id);
    perform util.validate_exists_by_id('content.capacities',          p_capacity_id);

    update content.cars set
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
create or replace function content.delete_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.cars', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.cars', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_USER_PROFILE_CAR  (junction)
-- ============================================================
create table junction.user_profile_cars (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,  -- [fix] добавлен is_deleted

    app_user_profile_id uuid    not null references profile.user_profiles(id),
    car_id              uuid    not null references content.cars(id)
);

create index idx_app_user_profile_car_id_hash
    on junction.user_profile_cars using hash (id);

create or replace function junction.create_app_user_profile_car(
    p_app_user_profile_id uuid,
    p_car_id              uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);
    perform util.validate_exists_by_id('content.cars',              p_car_id);

    select id into v_id from junction.user_profile_cars
    where app_user_profile_id = p_app_user_profile_id
      and car_id              = p_car_id
      and is_deleted          = true;

    if found then return util.set_entity_lifecycle('junction.user_profile_cars', v_id, false); end if;

    insert into junction.user_profile_cars (app_user_profile_id, car_id)
    values (p_app_user_profile_id, p_car_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_app_user_profile_cars()
returns setof junction.user_profile_cars language plpgsql as $$
begin
    return query select * from junction.user_profile_cars where is_deleted = false;
exception when others then return;
end;
$$;

create or replace function junction.get_app_user_profile_car_by_uuid(p_id uuid)
returns junction.user_profile_cars language plpgsql as $$
declare v_row junction.user_profile_cars;
begin
    select * into v_row from junction.user_profile_cars where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null;
end;
$$;

create or replace function junction.delete_app_user_profile_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.user_profile_cars', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_app_user_profile_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.user_profile_cars', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_BRAND  (junction)
-- ============================================================
create table junction.profile_filter_brands (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references profile.user_profiles(id),
    brand_id            uuid    not null references content.brands(id)
);

create index idx_profile_filter_brand_id_hash
    on junction.profile_filter_brands using hash (id);

create or replace function junction.create_profile_filter_brand(p_app_user_profile_id uuid, p_brand_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);
    perform util.validate_exists_by_id('content.brands',            p_brand_id);

    select id into v_id from junction.profile_filter_brands
    where app_user_profile_id = p_app_user_profile_id and brand_id = p_brand_id and is_deleted = true;

    if found then return util.set_entity_lifecycle('junction.profile_filter_brands', v_id, false); end if;

    insert into junction.profile_filter_brands (app_user_profile_id, brand_id)
    values (p_app_user_profile_id, p_brand_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_profile_filter_brands()
returns setof junction.profile_filter_brands language plpgsql as $$
begin return query select * from junction.profile_filter_brands where is_deleted = false;
exception when others then return; end;
$$;

create or replace function junction.get_profile_filter_brand_by_uuid(p_id uuid)
returns junction.profile_filter_brands language plpgsql as $$
declare v_row junction.profile_filter_brands;
begin
    select * into v_row from junction.profile_filter_brands where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function junction.delete_profile_filter_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_brands', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_profile_filter_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_brands', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_DRIVE_TYPE  (junction)
-- ============================================================
create table junction.profile_filter_drive_types (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references profile.user_profiles(id),
    drive_type_id       uuid    not null references content.drive_types(id)
);

create index idx_profile_filter_drive_type_id_hash
    on junction.profile_filter_drive_types using hash (id);

create or replace function junction.create_profile_filter_drive_type(p_app_user_profile_id uuid, p_drive_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);
    perform util.validate_exists_by_id('content.drive_types',       p_drive_type_id);

    select id into v_id from junction.profile_filter_drive_types
    where app_user_profile_id = p_app_user_profile_id and drive_type_id = p_drive_type_id and is_deleted = true;

    if found then return util.set_entity_lifecycle('junction.profile_filter_drive_types', v_id, false); end if;

    insert into junction.profile_filter_drive_types (app_user_profile_id, drive_type_id)
    values (p_app_user_profile_id, p_drive_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_profile_filter_drive_types()
returns setof junction.profile_filter_drive_types language plpgsql as $$
begin return query select * from junction.profile_filter_drive_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function junction.get_profile_filter_drive_type_by_uuid(p_id uuid)
returns junction.profile_filter_drive_types language plpgsql as $$
declare v_row junction.profile_filter_drive_types;
begin
    select * into v_row from junction.profile_filter_drive_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function junction.delete_profile_filter_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_drive_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_profile_filter_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_drive_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_TRANSMISSION_TYPE  (junction)
-- ============================================================
create table junction.profile_filter_transmission_types (
    id                   uuid    primary key default uuidv7(),

    is_deleted           boolean not null default false,

    app_user_profile_id  uuid    not null references profile.user_profiles(id),
    transmission_type_id uuid    not null references content.transmission_types(id)
);

create index idx_profile_filter_transmission_type_id_hash
    on junction.profile_filter_transmission_types using hash (id);

create or replace function junction.create_profile_filter_transmission_type(p_app_user_profile_id uuid, p_transmission_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles',  p_app_user_profile_id);
    perform util.validate_exists_by_id('content.transmission_types', p_transmission_type_id);

    select id into v_id from junction.profile_filter_transmission_types
    where app_user_profile_id = p_app_user_profile_id and transmission_type_id = p_transmission_type_id and is_deleted = true;

    if found then return util.set_entity_lifecycle('junction.profile_filter_transmission_types', v_id, false); end if;

    insert into junction.profile_filter_transmission_types (app_user_profile_id, transmission_type_id)
    values (p_app_user_profile_id, p_transmission_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_profile_filter_transmission_types()
returns setof junction.profile_filter_transmission_types language plpgsql as $$
begin return query select * from junction.profile_filter_transmission_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function junction.get_profile_filter_transmission_type_by_uuid(p_id uuid)
returns junction.profile_filter_transmission_types language plpgsql as $$
declare v_row junction.profile_filter_transmission_types;
begin
    select * into v_row from junction.profile_filter_transmission_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function junction.delete_profile_filter_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_transmission_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_profile_filter_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_transmission_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_USAGE_TYPE  (junction)
-- ============================================================
create table junction.profile_filter_usage_types (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references profile.user_profiles(id),
    usage_type_id       uuid    not null references content.usage_types(id)
);

create index idx_profile_filter_usage_type_id_hash
    on junction.profile_filter_usage_types using hash (id);

create or replace function junction.create_profile_filter_usage_type(p_app_user_profile_id uuid, p_usage_type_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);
    perform util.validate_exists_by_id('content.usage_types',       p_usage_type_id);

    select id into v_id from junction.profile_filter_usage_types
    where app_user_profile_id = p_app_user_profile_id and usage_type_id = p_usage_type_id and is_deleted = true;

    if found then return util.set_entity_lifecycle('junction.profile_filter_usage_types', v_id, false); end if;

    insert into junction.profile_filter_usage_types (app_user_profile_id, usage_type_id)
    values (p_app_user_profile_id, p_usage_type_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_profile_filter_usage_types()
returns setof junction.profile_filter_usage_types language plpgsql as $$
begin return query select * from junction.profile_filter_usage_types where is_deleted = false;
exception when others then return; end;
$$;

create or replace function junction.get_profile_filter_usage_type_by_uuid(p_id uuid)
returns junction.profile_filter_usage_types language plpgsql as $$
declare v_row junction.profile_filter_usage_types;
begin
    select * into v_row from junction.profile_filter_usage_types where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function junction.delete_profile_filter_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_usage_types', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_profile_filter_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_usage_types', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- PROFILE_FILTER_CAPACITY  (junction)
-- ============================================================
create table junction.profile_filter_capacities (
    id                  uuid    primary key default uuidv7(),

    is_deleted          boolean not null default false,

    app_user_profile_id uuid    not null references profile.user_profiles(id),
    capacity_id         uuid    not null references content.capacities(id)
);

create index idx_profile_filter_capacity_id_hash
    on junction.profile_filter_capacities using hash (id);

create or replace function junction.create_profile_filter_capacity(p_app_user_profile_id uuid, p_capacity_id uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('profile.user_profiles', p_app_user_profile_id);
    perform util.validate_exists_by_id('content.capacities',         p_capacity_id);

    select id into v_id from junction.profile_filter_capacities
    where app_user_profile_id = p_app_user_profile_id and capacity_id = p_capacity_id and is_deleted = true;

    if found then return util.set_entity_lifecycle('junction.profile_filter_capacities', v_id, false); end if;

    insert into junction.profile_filter_capacities (app_user_profile_id, capacity_id)
    values (p_app_user_profile_id, p_capacity_id) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function junction.get_profile_filter_capacities()
returns setof junction.profile_filter_capacities language plpgsql as $$
begin return query select * from junction.profile_filter_capacities where is_deleted = false;
exception when others then return; end;
$$;

create or replace function junction.get_profile_filter_capacity_by_uuid(p_id uuid)
returns junction.profile_filter_capacities language plpgsql as $$
declare v_row junction.profile_filter_capacities;
begin
    select * into v_row from junction.profile_filter_capacities where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function junction.delete_profile_filter_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_capacities', p_id, true);
exception when others then return null; end;
$$;

create or replace function junction.restore_profile_filter_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('junction.profile_filter_capacities', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_REQUEST
-- ============================================================
create table content.requests (
    id          uuid    primary key default uuidv7(),

    comment     text,
    is_deleted  boolean not null default false,

    app_user_id uuid    not null references app.users(id),
    car_id      uuid    not null references content.cars(id)
);

create index idx_app_request_id_hash
    on content.requests using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function content.create_app_request(
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
    perform util.validate_exists_by_id('app.users', p_app_user_id);
    perform util.validate_exists_by_id('content.cars',      p_car_id);

    -- [sanitize] comment опциональный — sanitize только если передан
    if p_comment is not null then
        p_comment := util.sanitize_text(p_comment, 'comment');
    end if;

    insert into content.requests (app_user_id, car_id, comment)
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
create or replace function content.get_app_requests()
returns setof content.requests language plpgsql as $$
begin return query select * from content.requests where is_deleted = false;
exception when others then return; end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_app_request_by_uuid(p_id uuid)
returns content.requests language plpgsql as $$
declare v_row content.requests;
begin
    select * into v_row from content.requests where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function content.update_app_request_by_uuid(
    p_id          uuid,
    p_app_user_id uuid,
    p_car_id      uuid,
    p_comment     text default null
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('app.users', p_app_user_id);
    perform util.validate_exists_by_id('content.cars',      p_car_id);

    if p_comment is not null then
        p_comment := util.sanitize_text(p_comment, 'comment');
    end if;

    update content.requests
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
create or replace function content.delete_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.requests', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.requests', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_ORDER
-- ============================================================
create table content.orders (
    id              uuid           primary key default uuidv7(),

    comment         text,
    order_date      date           not null,
    period_months   int            not null check (period_months > 0),
    down_payment    numeric(12, 2) not null check (down_payment > 0),
    monthly_payment numeric(12, 2) not null check (monthly_payment > 0),
    is_deleted      boolean        not null default false,

    app_user_id     uuid           not null references app.users(id),
    manager_id      uuid           not null references app.users(id),
    app_request_id  uuid           not null references content.requests(id)
);

create index idx_app_order_id_hash
    on content.orders using hash (id);


-- -------------------------------
-- create 1
-- -------------------------------
create or replace function content.create_app_order(
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
    perform util.validate_exists_by_id('app.users',    p_app_user_id);
    perform util.validate_exists_by_id('app.users',    p_manager_id);
    perform util.validate_exists_by_id('content.requests', p_app_request_id);

    if p_comment is not null then
        p_comment := util.sanitize_text(p_comment, 'comment');
    end if;

    insert into content.orders (
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
create or replace function content.get_app_orders()
returns setof content.orders language plpgsql as $$
begin return query select * from content.orders where is_deleted = false;
exception when others then return; end;
$$;

-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_app_order_by_uuid(p_id uuid)
returns content.orders language plpgsql as $$
declare v_row content.orders;
begin
    select * into v_row from content.orders where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

-- -------------------------------
-- update 1
-- -------------------------------
create or replace function content.update_app_order_by_uuid(
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
    perform util.validate_exists_by_id('app.users',    p_app_user_id);
    perform util.validate_exists_by_id('app.users',    p_manager_id);
    perform util.validate_exists_by_id('content.requests', p_app_request_id);

    if p_comment is not null then
        p_comment := util.sanitize_text(p_comment, 'comment');
    end if;

    update content.orders set
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
create or replace function content.delete_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.orders', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.orders', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_STATUS
-- ============================================================
-- [note] допустимые значения name:
--        'REQUEST_PENDING', 'REQUEST_ACCEPTED', 'REQUEST_CANCELLED',
--        'ORDER_PENDING',   'ORDER_ACCEPTED',   'ORDER_CANCELLED'
create table content.statuses (
    id         uuid         primary key default uuidv7(),

    name       varchar(100) unique not null,
    is_deleted boolean      not null default false
);

create index idx_app_status_id_hash
    on content.statuses using hash (id);

create or replace function content.create_app_status(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.statuses where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.statuses', v_id, false); end if;
    insert into content.statuses (name) values (p_name) returning id into v_id;
    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_app_statuses()
returns setof content.statuses language plpgsql as $$
begin return query select * from content.statuses where is_deleted = false;
exception when others then return; end;
$$;

create or replace function content.get_app_status_by_uuid(p_id uuid)
returns content.statuses language plpgsql as $$
declare v_row content.statuses;
begin
    select * into v_row from content.statuses where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;

create or replace function content.update_app_status_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.statuses set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    return v_id;
exception when others then return null; end;
$$;

create or replace function content.delete_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.statuses', p_id, true);
exception when others then return null; end;
$$;

create or replace function content.restore_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin return util.set_entity_lifecycle('content.statuses', p_id, false);
exception when others then return null; end;
$$;


-- ============================================================
-- APP_REQUEST_STATUS_HISTORY
-- ============================================================
-- [note] история — только append, физического удаления нет,
--        is_deleted добавлен для единообразия схемы.
create table content.request_status_histories (
    id             uuid        primary key default uuidv7(),

    created_at     timestamptz not null default now(),
    is_deleted     boolean     not null default false,

    app_status_id  uuid        not null references content.statuses(id),
    app_request_id uuid        not null references content.requests(id)
);

create index idx_app_request_status_history_id_hash
    on content.request_status_histories using hash (id);

create or replace function content.create_app_request_status_history(
    p_app_status_id  uuid,
    p_app_request_id uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('content.statuses',  p_app_status_id);
    perform util.validate_exists_by_id('content.requests', p_app_request_id);

    insert into content.request_status_histories (app_status_id, app_request_id)
    values (p_app_status_id, p_app_request_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_app_request_status_histories()
returns setof content.request_status_histories language plpgsql as $$
begin
    return query
    select * from content.request_status_histories
    where is_deleted = false
    order by created_at desc;
exception when others then return; end;
$$;

create or replace function content.get_app_request_status_history_by_uuid(p_id uuid)
returns content.request_status_histories language plpgsql as $$
declare v_row content.request_status_histories;
begin
    select * into v_row from content.request_status_histories where id = p_id and is_deleted = false;
    return v_row;
exception when others then return null; end;
$$;


-- ============================================================
-- APP_ORDER_STATUS_HISTORY
-- ============================================================
create table content.order_status_histories (
    id            uuid        primary key default uuidv7(),

    created_at    timestamptz not null default now(),
    is_deleted    boolean     not null default false,

    app_status_id uuid        not null references content.statuses(id),
    app_order_id  uuid        not null references content.orders(id)
);

create index idx_app_order_status_history_id_hash
    on content.order_status_histories using hash (id);

create or replace function content.create_app_order_status_history(
    p_app_status_id uuid,
    p_app_order_id  uuid
)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    perform util.validate_exists_by_id('content.statuses', p_app_status_id);
    perform util.validate_exists_by_id('content.orders',  p_app_order_id);

    insert into content.order_status_histories (app_status_id, app_order_id)
    values (p_app_status_id, p_app_order_id)
    returning id into v_id;

    return v_id;
exception when others then return null;
end;
$$;

create or replace function content.get_app_order_status_histories()
returns setof content.order_status_histories language plpgsql as $$
begin
    return query
    select * from content.order_status_histories
    where is_deleted = false
    order by created_at desc;
exception when others then return; end;
$$;

create or replace function content.get_app_order_status_history_by_uuid(p_id uuid)
returns content.order_status_histories language plpgsql as $$
declare v_row content.order_status_histories;
begin
    select * into v_row from content.order_status_histories where id = p_id and is_deleted = false;
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
grant execute on function util.sanitize_text(text, text)                 to role_guest, role_user, role_manager, role_admin;
grant execute on function util.is_record_active(text, uuid)              to role_guest, role_user, role_manager, role_admin;
grant execute on function util.validate_exists_by_id(text, uuid)         to role_guest, role_user, role_manager, role_admin;
grant execute on function util.set_entity_lifecycle(text, uuid, boolean) to role_user, role_manager, role_admin;


-- ============================================================
-- GRANT EXECUTE на CRUD-функции
-- ============================================================

-- -------------------------------
-- app.roles
-- admin: R C U D
-- -------------------------------
grant execute on function app.get_app_roles()                        to role_admin;
grant execute on function app.get_app_role_by_uuid(uuid)             to role_admin;
grant execute on function app.create_app_role(varchar)               to role_admin;
grant execute on function app.update_app_role_by_uuid(uuid, varchar) to role_admin;
grant execute on function app.delete_app_role_by_uuid(uuid)          to role_admin;
grant execute on function app.restore_app_role_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- profile.user_profiles
-- user:    R C U own
-- manager: R C U own
-- admin:   R C U D
-- [note] own реализуется через RLS — см. ниже
-- -------------------------------
grant execute on function profile.get_app_user_profiles()                              to role_user, role_manager, role_admin;
grant execute on function profile.get_app_user_profile_by_uuid(uuid)                   to role_user, role_manager, role_admin;
grant execute on function profile.create_app_user_profile(varchar, uuid)               to role_user, role_manager, role_admin;
grant execute on function profile.update_app_user_profile_by_uuid(uuid, varchar, uuid) to role_user, role_manager, role_admin;
grant execute on function profile.delete_app_user_profile_by_uuid(uuid)                to role_admin;
grant execute on function profile.restore_app_user_profile_by_uuid(uuid)               to role_admin;

-- -------------------------------
-- app.users
-- user:    R C U own
-- manager: R C U own
-- admin:   R C U D
-- -------------------------------
grant execute on function app.get_app_users()                                       to role_user, role_manager, role_admin;
grant execute on function app.get_app_user_by_uuid(uuid)                            to role_user, role_manager, role_admin;
grant execute on function app.create_app_user(varchar, varchar, uuid)               to role_user, role_manager, role_admin;
grant execute on function app.update_app_user_by_uuid(uuid, varchar, varchar, uuid) to role_user, role_manager, role_admin;
grant execute on function app.delete_app_user_by_uuid(uuid)                         to role_admin;
grant execute on function app.restore_app_user_by_uuid(uuid)                        to role_admin;

-- -------------------------------
-- content.brands
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_brands()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_brand_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_brand(varchar)               to role_admin;
grant execute on function content.update_brand_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_brand_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_brand_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- content.drive_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_drive_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_drive_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_drive_type(varchar)               to role_admin;
grant execute on function content.update_drive_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_drive_type_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_drive_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- content.transmission_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_transmission_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_transmission_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_transmission_type(varchar)               to role_admin;
grant execute on function content.update_transmission_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_transmission_type_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_transmission_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- content.usage_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_usage_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_usage_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_usage_type(varchar)               to role_admin;
grant execute on function content.update_usage_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_usage_type_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_usage_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- content.capacity_types
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_capacity_types()                        to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_capacity_type_by_uuid(uuid)             to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_capacity_type(varchar)               to role_admin;
grant execute on function content.update_capacity_type_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_capacity_type_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_capacity_type_by_uuid(uuid)         to role_admin;

-- -------------------------------
-- content.capacities
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_capacities()                         to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_capacity_by_uuid(uuid)               to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_capacity(int, uuid)               to role_admin;
grant execute on function content.update_capacity_by_uuid(uuid, int, uuid) to role_admin;
grant execute on function content.delete_capacity_by_uuid(uuid)            to role_admin;
grant execute on function content.restore_capacity_by_uuid(uuid)           to role_admin;

-- -------------------------------
-- content.cars
-- guest: R  |  user: R  |  manager: R  |  admin: R C U D
-- -------------------------------
grant execute on function content.get_cars()                                                                                    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_car_by_uuid(uuid)                                                                         to role_guest, role_user, role_manager, role_admin;
grant execute on function content.create_car(varchar, numeric, date, varchar, text, uuid, uuid, uuid, uuid, uuid)               to role_admin;
grant execute on function content.update_car_by_uuid(uuid, varchar, numeric, date, varchar, text, uuid, uuid, uuid, uuid, uuid) to role_admin;
grant execute on function content.delete_car_by_uuid(uuid)                                                                      to role_admin;
grant execute on function content.restore_car_by_uuid(uuid)                                                                     to role_admin;

-- -------------------------------
-- junction.user_profile_cars
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_app_user_profile_cars()                to role_user, role_manager, role_admin;
grant execute on function junction.get_app_user_profile_car_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_app_user_profile_car(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_app_user_profile_car_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_app_user_profile_car_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- junction.profile_filter_brands
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_profile_filter_brands()                to role_user, role_manager, role_admin;
grant execute on function junction.get_profile_filter_brand_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_profile_filter_brand(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_profile_filter_brand_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_profile_filter_brand_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- junction.profile_filter_drive_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_profile_filter_drive_types()                to role_user, role_manager, role_admin;
grant execute on function junction.get_profile_filter_drive_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_profile_filter_drive_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_profile_filter_drive_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_profile_filter_drive_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- junction.profile_filter_transmission_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_profile_filter_transmission_types()                to role_user, role_manager, role_admin;
grant execute on function junction.get_profile_filter_transmission_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_profile_filter_transmission_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_profile_filter_transmission_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_profile_filter_transmission_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- junction.profile_filter_usage_types
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_profile_filter_usage_types()                to role_user, role_manager, role_admin;
grant execute on function junction.get_profile_filter_usage_type_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_profile_filter_usage_type(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_profile_filter_usage_type_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_profile_filter_usage_type_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- junction.profile_filter_capacities
-- user:    R C D own
-- manager: R C D own
-- admin:   R C U D
-- -------------------------------
grant execute on function junction.get_profile_filter_capacities()               to role_user, role_manager, role_admin;
grant execute on function junction.get_profile_filter_capacity_by_uuid(uuid)     to role_user, role_manager, role_admin;
grant execute on function junction.create_profile_filter_capacity(uuid, uuid)    to role_user, role_manager, role_admin;
grant execute on function junction.delete_profile_filter_capacity_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function junction.restore_profile_filter_capacity_by_uuid(uuid) to role_user, role_manager, role_admin;

-- -------------------------------
-- content.requests
-- user:    R C own
-- manager: R all C U D
-- admin:   R C U D
-- -------------------------------
grant execute on function content.get_app_requests()                                 to role_user, role_manager, role_admin;
grant execute on function content.get_app_request_by_uuid(uuid)                      to role_user, role_manager, role_admin;
grant execute on function content.create_app_request(uuid, uuid, text)               to role_user, role_manager, role_admin;
grant execute on function content.update_app_request_by_uuid(uuid, uuid, uuid, text) to role_manager, role_admin;
grant execute on function content.delete_app_request_by_uuid(uuid)                   to role_manager, role_admin;
grant execute on function content.restore_app_request_by_uuid(uuid)                  to role_manager, role_admin;

-- -------------------------------
-- content.orders
-- user:    R own
-- manager: R all C U
-- admin:   R C U D
-- -------------------------------
grant execute on function content.get_app_orders()                                                                    to role_user, role_manager, role_admin;
grant execute on function content.get_app_order_by_uuid(uuid)                                                         to role_user, role_manager, role_admin;
grant execute on function content.create_app_order(date, int, numeric, numeric, uuid, uuid, uuid, text)               to role_manager, role_admin;
grant execute on function content.update_app_order_by_uuid(uuid, date, int, numeric, numeric, uuid, uuid, uuid, text) to role_manager, role_admin;
grant execute on function content.delete_app_order_by_uuid(uuid)                                                      to role_admin;
grant execute on function content.restore_app_order_by_uuid(uuid)                                                     to role_admin;


-- -------------------------------
-- content.statuses
-- manager: R
-- admin:   R C U D
-- -------------------------------
grant execute on function content.get_app_statuses()                       to role_manager, role_admin;
grant execute on function content.get_app_status_by_uuid(uuid)             to role_manager, role_admin;
grant execute on function content.create_app_status(varchar)               to role_admin;
grant execute on function content.update_app_status_by_uuid(uuid, varchar) to role_admin;
grant execute on function content.delete_app_status_by_uuid(uuid)          to role_admin;
grant execute on function content.restore_app_status_by_uuid(uuid)         to role_admin;


-- -------------------------------
-- content.request_status_histories
-- user:    R own
-- manager: R all C
-- admin:   R C
-- [note] append-only — delete/restore нет ни у кого
-- -------------------------------
grant execute on function content.get_app_request_status_histories()            to role_user, role_manager, role_admin;
grant execute on function content.get_app_request_status_history_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function content.create_app_request_status_history(uuid, uuid) to role_manager, role_admin;


-- -------------------------------
-- content.order_status_histories
-- user:    R own
-- manager: R all C
-- admin:   R C
-- [note] append-only — delete/restore нет ни у кого
-- -------------------------------
grant execute on function content.get_app_order_status_histories()            to role_user, role_manager, role_admin;
grant execute on function content.get_app_order_status_history_by_uuid(uuid)  to role_user, role_manager, role_admin;
grant execute on function content.create_app_order_status_history(uuid, uuid) to role_manager, role_admin;



-- ============================================================
-- TABLE-LEVEL GRANT
-- ============================================================


-- -------------------------------
-- SELECT — все таблицы
-- нужен для get*, is_record_active, validate_exists_by_id
-- -------------------------------
grant select on
    app.roles,
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    junction.user_profile_cars,
    junction.profile_filter_brands,
    junction.profile_filter_drive_types,
    junction.profile_filter_transmission_types,
    junction.profile_filter_usage_types,
    junction.profile_filter_capacities,
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_guest, role_user, role_manager, role_admin;


-- -------------------------------
-- INSERT — все таблицы
-- нужен для create_*
-- -------------------------------
grant insert on
    app.roles,
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    junction.user_profile_cars,
    junction.profile_filter_brands,
    junction.profile_filter_drive_types,
    junction.profile_filter_transmission_types,
    junction.profile_filter_usage_types,
    junction.profile_filter_capacities,
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_user, role_manager, role_admin;


-- -------------------------------
-- UPDATE — не-history таблицы
-- нужен для update_*, delete_* soft, restore_*
-- history — только append, update не нужен
-- -------------------------------
grant update on
    app.roles,
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    junction.user_profile_cars,
    junction.profile_filter_brands,
    junction.profile_filter_drive_types,
    junction.profile_filter_transmission_types,
    junction.profile_filter_usage_types,
    junction.profile_filter_capacities,
    content.requests,
    content.orders,
    content.statuses
to role_user, role_manager, role_admin;

-- ============================================================
-- AUDIT SCHEMA — таблица и триггер логирования DML
-- ============================================================
create table audit.dml_logs (
    id            uuid         primary key default uuidv7(),
    role_name     text         not null,
    table_schema  text         not null,
    table_name    text         not null,
    dml_operation text         not null,   -- INSERT | UPDATE | DELETE
    occurred_at   timestamptz  not null default now()
);

create index idx_dml_logs_role      on audit.dml_logs (role_name);
create index idx_dml_logs_table     on audit.dml_logs (table_schema, table_name);
create index idx_dml_logs_operation on audit.dml_logs (dml_operation);
create index idx_dml_logs_time      on audit.dml_logs (occurred_at desc);


-- ─── триггерная функция ─────────────────────────────────────
create or replace function audit.log_dml_operation()
returns trigger
language plpgsql
security definer          -- выполняется от владельца, чтобы любая роль могла писать в audit.dml_logs
as $$
begin
    insert into audit.dml_logs (role_name, table_schema, table_name, dml_operation)
    values (
        current_user,        -- роль, от имени которой выполняется операция
        tg_table_schema,     -- схема таблицы (из специальных переменных триггера)
        tg_table_name,       -- имя таблицы
        tg_op                -- INSERT | UPDATE | DELETE
    );
    return null;             -- AFTER-триггер, return null разрешён
end;
$$;


-- ─── вспомогательная функция: навесить триггер на таблицу ───
-- [note] используется ниже для DRY-установки триггеров
create or replace function audit.attach_dml_trigger(
    p_schema text,
    p_table  text
)
returns void
language plpgsql
as $$
declare
    v_trigger_name text;
begin
    v_trigger_name := 'trg_audit_dml__' || p_schema || '__' || p_table;
    execute format(
        $fmt$
        create trigger %I
        after insert or update or delete
        on %I.%I
        for each row execute function audit.log_dml_operation()
        $fmt$,
        v_trigger_name,
        p_schema,
        p_table
    );
end;
$$;


-- ─── установка триггеров на все таблицы ─────────────────────

-- app
select audit.attach_dml_trigger('app', 'roles');
select audit.attach_dml_trigger('app', 'users');

-- profile
select audit.attach_dml_trigger('profile', 'user_profiles');

-- content
select audit.attach_dml_trigger('content', 'brands');
select audit.attach_dml_trigger('content', 'drive_types');
select audit.attach_dml_trigger('content', 'transmission_types');
select audit.attach_dml_trigger('content', 'usage_types');
select audit.attach_dml_trigger('content', 'capacity_types');
select audit.attach_dml_trigger('content', 'capacities');
select audit.attach_dml_trigger('content', 'cars');
select audit.attach_dml_trigger('content', 'requests');
select audit.attach_dml_trigger('content', 'orders');
select audit.attach_dml_trigger('content', 'statuses');
select audit.attach_dml_trigger('content', 'request_status_histories');
select audit.attach_dml_trigger('content', 'order_status_histories');

-- junction
select audit.attach_dml_trigger('junction', 'user_profile_cars');
select audit.attach_dml_trigger('junction', 'profile_filter_brands');
select audit.attach_dml_trigger('junction', 'profile_filter_drive_types');
select audit.attach_dml_trigger('junction', 'profile_filter_transmission_types');
select audit.attach_dml_trigger('junction', 'profile_filter_usage_types');
select audit.attach_dml_trigger('junction', 'profile_filter_capacities');


-- ─── права на audit ─────────────────────────────────────────
-- роли не имеют прямого доступа к audit.dml_logs — только через security definer функцию
-- только admin может читать логи напрямую
grant select on audit.dml_logs to role_admin;

-- execute на вспомогательные audit-функции — только для суперпользователя/владельца БД
-- attach_dml_trigger вызывается при инициализации, не нужен ролям приложения