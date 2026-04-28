-- ============================================================
-- SCHEMAS
-- ============================================================
create schema if not exists app;
create schema if not exists profile;
create schema if not exists content;
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


-- [fix] убрали exception-блок — ошибки пробрасываются наверх как текст,
--       а не проглатываются с возвратом null
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
        raise exception 'sanitize_text: % must not be empty', p_field_name
            using errcode = 'check_violation';
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
end;
$$;


-- [fix] убрали exception-блок — ошибка пробрасывается наверх с понятным текстом
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
            p_table_name, p_id
            using errcode = 'foreign_key_violation';
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

    -- [fix] если запись не найдена — явная ошибка вместо тихого null
    if v_id is null then
        raise exception
            'set_entity_lifecycle: record not found in %.id = %',
            p_table_name, p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
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
-- [fix] вместо `exception when others then return null` — пробрасываем ошибку
--       с понятным контекстом через RAISE ... USING DETAIL
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
        raise exception 'create_app_role: %', sqlerrm
            using detail  = format('name = %L', p_name),
                  errcode = sqlstate;
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
        raise exception 'get_app_roles: %', sqlerrm
            using errcode = sqlstate;
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

    if not found then
        raise exception 'get_app_role_by_uuid: role not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_row;
exception
    when others then
        raise exception 'get_app_role_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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

    if v_id is null then
        raise exception 'update_app_role_by_uuid: role not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_app_role_by_uuid: %', sqlerrm
            using detail  = format('id = %L, name = %L', p_id, p_name),
                  errcode = sqlstate;
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
        raise exception 'delete_app_role_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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
        raise exception 'restore_app_role_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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

    insert into profile.user_profiles (name, app_role_id)
    values (p_name, p_app_role_id)
    returning id into v_id;

    return v_id;
exception
    when others then
        raise exception 'create_app_user_profile: %', sqlerrm
            using detail  = format('name = %L, app_role_id = %L', p_name, p_app_role_id),
                  errcode = sqlstate;
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
        raise exception 'get_app_user_profiles: %', sqlerrm
            using errcode = sqlstate;
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

    if not found then
        raise exception 'get_app_user_profile_by_uuid: profile not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_row;
exception
    when others then
        raise exception 'get_app_user_profile_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own
-- -------------------------------
create or replace function profile.get_own_app_user_profile(
    p_current_user_id uuid
)
returns profile.user_profiles
language plpgsql
as $$
declare
    v_user app.users;
    v_profile profile.user_profiles;
begin
    -- 1) находим активного пользователя
    select *
    into v_user
    from app.users
    where id = p_current_user_id
      and is_deleted = false;

    if not found then
        raise exception 'get_own_app_user_profile: user not found, id = %', p_current_user_id
            using errcode = 'no_data_found';
    end if;

    -- 2) находим профиль по FK
    select *
    into v_profile
    from profile.user_profiles
    where id = v_user.app_user_profile_id
      and is_deleted = false;

    if not found then
        raise exception 'get_own_app_user_profile: profile not found, id = %',
            v_user.app_user_profile_id
            using errcode = 'no_data_found';
    end if;

    return v_profile;
exception
    when others then
        raise exception 'get_own_app_user_profile: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
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

    if v_id is null then
        raise exception 'update_app_user_profile_by_uuid: profile not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_app_user_profile_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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
        raise exception 'delete_app_user_profile_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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
        raise exception 'restore_app_user_profile_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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


create index if not exists idx_app_user_profile_id_hash2
    on app.users using hash (app_user_profile_id);


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
        raise exception 'create_app_user: %', sqlerrm
            using detail  = format('email = %L', p_email),
                  errcode = sqlstate;
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
        raise exception 'get_app_users: %', sqlerrm
            using errcode = sqlstate;
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

    if not found then
        raise exception 'get_app_user_by_uuid: user not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_row;
exception
    when others then
        raise exception 'get_app_user_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own
-- -------------------------------
create or replace function app.get_own_app_user(
    p_current_user_id uuid
)
returns app.users
language plpgsql
as $$
declare
    v_user app.users;
begin
    select *
    into v_user
    from app.users
    where id = p_current_user_id
      and is_deleted = false;

    if not found then
        raise exception 'get_own_app_user: user not found, id = %', p_current_user_id
            using errcode = 'no_data_found';
    end if;

    return v_user;
exception
    when others then
        raise exception 'get_own_app_user: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
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

    if v_id is null then
        raise exception 'update_app_user_by_uuid: user not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_app_user_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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
        raise exception 'delete_app_user_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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
        raise exception 'restore_app_user_by_uuid: %', sqlerrm
            using detail  = format('id = %L', p_id),
                  errcode = sqlstate;
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

create or replace function content.create_brand(p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    select id into v_id from content.brands where name = p_name and is_deleted = true;
    if found then return util.set_entity_lifecycle('content.brands', v_id, false); end if;
    insert into content.brands (name) values (p_name) returning id into v_id;
    return v_id;
exception
    when others then
        raise exception 'create_brand: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_brands()
returns setof content.brands language plpgsql as $$
begin
    return query select * from content.brands where is_deleted = false;
exception
    when others then
        raise exception 'get_brands: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_brand_by_uuid(p_id uuid)
returns content.brands language plpgsql as $$
declare v_row content.brands;
begin
    select * into v_row from content.brands where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_brand_by_uuid: brand not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_brand_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_brand_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.brands set name = p_name
    where id = p_id and is_deleted = false
    returning id into v_id;
    if v_id is null then
        raise exception 'update_brand_by_uuid: brand not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_brand_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.brands', p_id, true);
exception
    when others then
        raise exception 'delete_brand_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_brand_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.brands', p_id, false);
exception
    when others then
        raise exception 'restore_brand_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
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
exception
    when others then
        raise exception 'create_drive_type: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_drive_types()
returns setof content.drive_types language plpgsql as $$
begin
    return query select * from content.drive_types where is_deleted = false;
exception
    when others then
        raise exception 'get_drive_types: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_drive_type_by_uuid(p_id uuid)
returns content.drive_types language plpgsql as $$
declare v_row content.drive_types;
begin
    select * into v_row from content.drive_types where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_drive_type_by_uuid: drive type not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_drive_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_drive_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.drive_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    if v_id is null then
        raise exception 'update_drive_type_by_uuid: drive type not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_drive_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.drive_types', p_id, true);
exception
    when others then
        raise exception 'delete_drive_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_drive_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.drive_types', p_id, false);
exception
    when others then
        raise exception 'restore_drive_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
exception
    when others then
        raise exception 'create_transmission_type: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_transmission_types()
returns setof content.transmission_types language plpgsql as $$
begin
    return query select * from content.transmission_types where is_deleted = false;
exception
    when others then
        raise exception 'get_transmission_types: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_transmission_type_by_uuid(p_id uuid)
returns content.transmission_types language plpgsql as $$
declare v_row content.transmission_types;
begin
    select * into v_row from content.transmission_types where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_transmission_type_by_uuid: transmission type not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_transmission_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_transmission_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.transmission_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    if v_id is null then
        raise exception 'update_transmission_type_by_uuid: transmission type not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_transmission_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.transmission_types', p_id, true);
exception
    when others then
        raise exception 'delete_transmission_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_transmission_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.transmission_types', p_id, false);
exception
    when others then
        raise exception 'restore_transmission_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
exception
    when others then
        raise exception 'create_usage_type: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_usage_types()
returns setof content.usage_types language plpgsql as $$
begin
    return query select * from content.usage_types where is_deleted = false;
exception
    when others then
        raise exception 'get_usage_types: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_usage_type_by_uuid(p_id uuid)
returns content.usage_types language plpgsql as $$
declare v_row content.usage_types;
begin
    select * into v_row from content.usage_types where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_usage_type_by_uuid: usage type not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_usage_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_usage_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.usage_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    if v_id is null then
        raise exception 'update_usage_type_by_uuid: usage type not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_usage_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.usage_types', p_id, true);
exception
    when others then
        raise exception 'delete_usage_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_usage_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.usage_types', p_id, false);
exception
    when others then
        raise exception 'restore_usage_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
exception
    when others then
        raise exception 'create_capacity_type: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_capacity_types()
returns setof content.capacity_types language plpgsql as $$
begin
    return query select * from content.capacity_types where is_deleted = false;
exception
    when others then
        raise exception 'get_capacity_types: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_capacity_type_by_uuid(p_id uuid)
returns content.capacity_types language plpgsql as $$
declare v_row content.capacity_types;
begin
    select * into v_row from content.capacity_types where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_capacity_type_by_uuid: capacity type not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_capacity_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_capacity_type_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.capacity_types set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    if v_id is null then
        raise exception 'update_capacity_type_by_uuid: capacity type not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_capacity_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.capacity_types', p_id, true);
exception
    when others then
        raise exception 'delete_capacity_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_capacity_type_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.capacity_types', p_id, false);
exception
    when others then
        raise exception 'restore_capacity_type_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
        raise exception 'create_capacity: %', sqlerrm
            using detail  = format('value = %L, capacity_type_id = %L', p_value, p_capacity_type_id),
                  errcode = sqlstate;
end;
$$;

create or replace function content.get_capacities()
returns setof content.capacities language plpgsql as $$
begin
    return query select * from content.capacities where is_deleted = false;
exception
    when others then
        raise exception 'get_capacities: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_capacity_by_uuid(p_id uuid)
returns content.capacities language plpgsql as $$
declare v_row content.capacities;
begin
    select * into v_row from content.capacities where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_capacity_by_uuid: capacity not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_capacity_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

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
    if v_id is null then
        raise exception 'update_capacity_by_uuid: capacity not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_capacity_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.capacities', p_id, true);
exception
    when others then
        raise exception 'delete_capacity_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_capacity_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.capacities', p_id, false);
exception
    when others then
        raise exception 'restore_capacity_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
    p_name              := util.sanitize_text(p_name,              'name');
    p_country_of_origin := util.sanitize_text(p_country_of_origin, 'country_of_origin');
    p_description       := util.sanitize_text(p_description,       'description');

    -- [validate fk]
    perform util.validate_exists_by_id('content.brands',             p_brand_id);
    perform util.validate_exists_by_id('content.drive_types',        p_drive_type_id);
    perform util.validate_exists_by_id('content.transmission_types', p_transmission_type_id);
    perform util.validate_exists_by_id('content.usage_types',        p_usage_type_id);
    perform util.validate_exists_by_id('content.capacities',         p_capacity_id);

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
        raise exception 'create_car: %', sqlerrm
            using detail  = format('name = %L', p_name),
                  errcode = sqlstate;
end;
$$;

create or replace function content.get_cars()
returns setof content.cars language plpgsql as $$
begin
    return query select * from content.cars where is_deleted = false;
exception
    when others then
        raise exception 'get_cars: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_car_by_uuid(p_id uuid)
returns content.cars language plpgsql as $$
declare v_row content.cars;
begin
    select * into v_row from content.cars where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_car_by_uuid: car not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_car_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

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
    perform util.validate_exists_by_id('content.capacities',         p_capacity_id);

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

    if v_id is null then
        raise exception 'update_car_by_uuid: car not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_car_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.cars', p_id, true);
exception
    when others then
        raise exception 'delete_car_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_car_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.cars', p_id, false);
exception
    when others then
        raise exception 'restore_car_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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

create index if not exists idx_app_request_app_user_id_hash
    on content.requests using hash (app_user_id);


-- -------------------------------
-- create
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
    perform util.validate_exists_by_id('app.users',    p_app_user_id);
    perform util.validate_exists_by_id('content.cars', p_car_id);

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
        raise exception 'create_app_request: %', sqlerrm
            using detail  = format('user_id = %L, car_id = %L', p_app_user_id, p_car_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function content.get_app_requests()
returns setof content.requests language plpgsql as $$
begin
    return query select * from content.requests where is_deleted = false;
exception
    when others then
        raise exception 'get_app_requests: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_app_request_by_uuid(p_id uuid)
returns content.requests language plpgsql as $$
declare v_row content.requests;
begin
    select * into v_row from content.requests where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_app_request_by_uuid: request not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_app_request_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own many
-- -------------------------------
create or replace function content.get_own_app_requests(
    p_current_user_id uuid
)
returns setof content.requests
language plpgsql
as $$
begin
    return query
    select *
    from content.requests
    where is_deleted = false
      and app_user_id = p_current_user_id;
exception
    when others then
        raise exception 'get_own_app_requests: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own 1
-- -------------------------------
create or replace function content.get_own_app_request_by_uuid(
    p_current_user_id uuid,
    p_request_id      uuid
)
returns content.requests
language plpgsql
as $$
declare
    v_row content.requests;
begin
    select *
    into v_row
    from content.requests
    where id = p_request_id
      and app_user_id = p_current_user_id
      and is_deleted = false;

    if not found then
        raise exception 'get_own_app_request_by_uuid: request not found or not owned, id = %, user_id = %',
            p_request_id, p_current_user_id
            using errcode = 'no_data_found';
    end if;

    return v_row;
exception
    when others then
        raise exception 'get_own_app_request_by_uuid: %', sqlerrm
            using detail  = format('request_id = %L, current_user_id = %L',
                                   p_request_id, p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- update
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
    perform util.validate_exists_by_id('app.users',    p_app_user_id);
    perform util.validate_exists_by_id('content.cars', p_car_id);

    if p_comment is not null then
        p_comment := util.sanitize_text(p_comment, 'comment');
    end if;

    update content.requests
    set app_user_id = p_app_user_id,
        car_id      = p_car_id,
        comment     = p_comment
    where id = p_id and is_deleted = false
    returning id into v_id;

    if v_id is null then
        raise exception 'update_app_request_by_uuid: request not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_app_request_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- delete
-- -------------------------------
create or replace function content.delete_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.requests', p_id, true);
exception
    when others then
        raise exception 'delete_app_request_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- restore
-- -------------------------------
create or replace function content.restore_app_request_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.requests', p_id, false);
exception
    when others then
        raise exception 'restore_app_request_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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


create index if not exists idx_app_order_app_user_id_hash
    on content.orders using hash (app_user_id);


-- -------------------------------
-- create
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
    perform util.validate_exists_by_id('app.users',        p_app_user_id);
    perform util.validate_exists_by_id('app.users',        p_manager_id);
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
        raise exception 'create_app_order: %', sqlerrm
            using detail  = format('user_id = %L, request_id = %L', p_app_user_id, p_app_request_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function content.get_app_orders()
returns setof content.orders language plpgsql as $$
begin
    return query select * from content.orders where is_deleted = false;
exception
    when others then
        raise exception 'get_app_orders: %', sqlerrm using errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_app_order_by_uuid(p_id uuid)
returns content.orders language plpgsql as $$
declare v_row content.orders;
begin
    select * into v_row from content.orders where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_app_order_by_uuid: order not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_app_order_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own many
-- -------------------------------
create or replace function content.get_own_app_orders(
    p_current_user_id uuid
)
returns setof content.orders
language plpgsql
as $$
begin
    return query
    select *
    from content.orders
    where is_deleted = false
      and app_user_id = p_current_user_id;
exception
    when others then
        raise exception 'get_own_app_orders: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own 1
-- -------------------------------
create or replace function content.get_own_app_order_by_uuid(
    p_current_user_id uuid,
    p_order_id        uuid
)
returns content.orders
language plpgsql
as $$
declare
    v_row content.orders;
begin
    select *
    into v_row
    from content.orders
    where id = p_order_id
      and app_user_id = p_current_user_id
      and is_deleted = false;

    if not found then
        raise exception 'get_own_app_order_by_uuid: order not found or not owned, id = %, user_id = %',
            p_order_id, p_current_user_id
            using errcode = 'no_data_found';
    end if;

    return v_row;
exception
    when others then
        raise exception 'get_own_app_order_by_uuid: %', sqlerrm
            using detail  = format('order_id = %L, current_user_id = %L',
                                   p_order_id, p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- update
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
    perform util.validate_exists_by_id('app.users',        p_app_user_id);
    perform util.validate_exists_by_id('app.users',        p_manager_id);
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

    if v_id is null then
        raise exception 'update_app_order_by_uuid: order not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;

    return v_id;
exception
    when others then
        raise exception 'update_app_order_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get delte
-- -------------------------------
create or replace function content.delete_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.orders', p_id, true);
exception
    when others then
        raise exception 'delete_app_order_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get restore
-- -------------------------------
create or replace function content.restore_app_order_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.orders', p_id, false);
exception
    when others then
        raise exception 'restore_app_order_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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
exception
    when others then
        raise exception 'create_app_status: %', sqlerrm
            using detail = format('name = %L', p_name), errcode = sqlstate;
end;
$$;

create or replace function content.get_app_statuses()
returns setof content.statuses language plpgsql as $$
begin
    return query select * from content.statuses where is_deleted = false;
exception
    when others then
        raise exception 'get_app_statuses: %', sqlerrm using errcode = sqlstate;
end;
$$;

create or replace function content.get_app_status_by_uuid(p_id uuid)
returns content.statuses language plpgsql as $$
declare v_row content.statuses;
begin
    select * into v_row from content.statuses where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_app_status_by_uuid: status not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_app_status_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.update_app_status_by_uuid(p_id uuid, p_name varchar(100))
returns uuid language plpgsql as $$
declare v_id uuid;
begin
    p_name := util.sanitize_text(p_name, 'name');
    update content.statuses set name = p_name where id = p_id and is_deleted = false returning id into v_id;
    if v_id is null then
        raise exception 'update_app_status_by_uuid: status not found or deleted, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_id;
exception
    when others then
        raise exception 'update_app_status_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.delete_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.statuses', p_id, true);
exception
    when others then
        raise exception 'delete_app_status_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;

create or replace function content.restore_app_status_by_uuid(p_id uuid)
returns uuid language plpgsql as $$
begin
    return util.set_entity_lifecycle('content.statuses', p_id, false);
exception
    when others then
        raise exception 'restore_app_status_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
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

create index if not exists idx_app_request_status_history_request_id_hash
    on content.request_status_histories using hash (app_request_id);


-- -------------------------------
-- create
-- -------------------------------
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
exception
    when others then
        raise exception 'create_app_request_status_history: %', sqlerrm
            using detail  = format('status_id = %L, request_id = %L', p_app_status_id, p_app_request_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function content.get_app_request_status_histories()
returns setof content.request_status_histories language plpgsql as $$
begin
    return query
    select * from content.request_status_histories
    where is_deleted = false
    order by created_at desc;
exception
    when others then
        raise exception 'get_app_request_status_histories: %', sqlerrm using errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_app_request_status_history_by_uuid(p_id uuid)
returns content.request_status_histories language plpgsql as $$
declare v_row content.request_status_histories;
begin
    select * into v_row from content.request_status_histories where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_app_request_status_history_by_uuid: record not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_app_request_status_history_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own many
-- -------------------------------
create or replace function content.get_own_app_request_status_histories(
    p_current_user_id uuid
)
returns setof content.request_status_histories
language plpgsql
as $$
begin
    return query
    select rsh.*
    from content.request_status_histories rsh
    join content.requests r
      on rsh.app_request_id = r.id
    where r.is_deleted = false
      and rsh.is_deleted = false
      and r.app_user_id = p_current_user_id
    order by rsh.created_at desc;
exception
    when others then
        raise exception 'get_own_app_request_status_histories: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own 1
-- -------------------------------
create or replace function content.get_own_app_requests(
    p_current_user_id uuid
)
returns setof content.requests
language plpgsql
as $$
begin
    return query
    select *
    from content.requests
    where is_deleted = false
      and app_user_id = p_current_user_id;
exception
    when others then
        raise exception 'get_own_app_requests: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
end;
$$;
create or replace function content.get_own_app_request_status_histories_by_request(
    p_current_user_id uuid,
    p_request_id      uuid
)
returns setof content.request_status_histories
language plpgsql
as $$
begin
    -- проверяем, что заявка принадлежит пользователю и не удалена
    if not util.is_record_active('content.requests', p_request_id) then
        raise exception 'get_own_app_request_status_histories_by_request: request not found or deleted, id = %',
            p_request_id
            using errcode = 'no_data_found';
    end if;

    if not exists (
        select 1
        from content.requests r
        where r.id = p_request_id
          and r.app_user_id = p_current_user_id
          and r.is_deleted = false
    ) then
        raise exception 'get_own_app_request_status_histories_by_request: request does not belong to user, id = %, user_id = %',
            p_request_id, p_current_user_id
            using errcode = 'no_data_found';
    end if;

    return query
    select rsh.*
    from content.request_status_histories rsh
    where rsh.app_request_id = p_request_id
      and rsh.is_deleted = false
    order by rsh.created_at desc;
exception
    when others then
        raise exception 'get_own_app_request_status_histories_by_request: %', sqlerrm
            using detail  = format('request_id = %L, current_user_id = %L',
                                   p_request_id, p_current_user_id),
                  errcode = sqlstate;
end;
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


create index if not exists idx_app_order_status_history_order_id_hash
    on content.order_status_histories using hash (app_order_id);


-- -------------------------------
-- create
-- -------------------------------
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
exception
    when others then
        raise exception 'create_app_order_status_history: %', sqlerrm
            using detail  = format('status_id = %L, order_id = %L', p_app_status_id, p_app_order_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get many
-- -------------------------------
create or replace function content.get_app_order_status_histories()
returns setof content.order_status_histories language plpgsql as $$
begin
    return query
    select * from content.order_status_histories
    where is_deleted = false
    order by created_at desc;
exception
    when others then
        raise exception 'get_app_order_status_histories: %', sqlerrm using errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get 1
-- -------------------------------
create or replace function content.get_app_order_status_history_by_uuid(p_id uuid)
returns content.order_status_histories language plpgsql as $$
declare v_row content.order_status_histories;
begin
    select * into v_row from content.order_status_histories where id = p_id and is_deleted = false;
    if not found then
        raise exception 'get_app_order_status_history_by_uuid: record not found, id = %', p_id
            using errcode = 'no_data_found';
    end if;
    return v_row;
exception
    when others then
        raise exception 'get_app_order_status_history_by_uuid: %', sqlerrm
            using detail = format('id = %L', p_id), errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own many
-- -------------------------------
create or replace function content.get_own_app_order_status_histories(
    p_current_user_id uuid
)
returns setof content.order_status_histories
language plpgsql
as $$
begin
    return query
    select osh.*
    from content.order_status_histories osh
    join content.orders o
      on osh.app_order_id = o.id
    where o.is_deleted = false
      and osh.is_deleted = false
      and o.app_user_id = p_current_user_id
    order by osh.created_at desc;
exception
    when others then
        raise exception 'get_own_app_order_status_histories: %', sqlerrm
            using detail  = format('current_user_id = %L', p_current_user_id),
                  errcode = sqlstate;
end;
$$;


-- -------------------------------
-- get own 1
-- -------------------------------
create or replace function content.get_own_app_order_status_histories_by_order(
    p_current_user_id uuid,
    p_order_id        uuid
)
returns setof content.order_status_histories
language plpgsql
as $$
begin
    -- проверяем, что заказ активен
    if not util.is_record_active('content.orders', p_order_id) then
        raise exception 'get_own_app_order_status_histories_by_order: order not found or deleted, id = %',
            p_order_id
            using errcode = 'no_data_found';
    end if;

    if not exists (
        select 1
        from content.orders o
        where o.id = p_order_id
          and o.app_user_id = p_current_user_id
          and o.is_deleted = false
    ) then
        raise exception 'get_own_app_order_status_histories_by_order: order does not belong to user, id = %, user_id = %',
            p_order_id, p_current_user_id
            using errcode = 'no_data_found';
    end if;

    return query
    select osh.*
    from content.order_status_histories osh
    where osh.app_order_id = p_order_id
      and osh.is_deleted = false
    order by osh.created_at desc;
exception
    when others then
        raise exception 'get_own_app_order_status_histories_by_order: %', sqlerrm
            using detail  = format('order_id = %L, current_user_id = %L',
                                   p_order_id, p_current_user_id),
                  errcode = sqlstate;
end;
$$;


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


-- ─── права на audit ─────────────────────────────────────────
-- [note] прямой SELECT на audit.dml_logs — только admin (выдан выше в TABLE-LEVEL GRANTS)
-- [note] роли не имеют прямого доступа к audit.dml_logs — только через security definer триггер
-- [note] attach_dml_trigger вызывается при инициализации, не нужен ролям приложения



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
-- ROLES (group roles, NOLOGIN)
-- ============================================================
do
$$
begin
    if not exists (select 1 from pg_roles where rolname = 'role_guest') then
        create role role_guest nologin;
    end if;

    if not exists (select 1 from pg_roles where rolname = 'role_user') then
        create role role_user nologin;
    end if;

    if not exists (select 1 from pg_roles where rolname = 'role_manager') then
        create role role_manager nologin;
    end if;

    if not exists (select 1 from pg_roles where rolname = 'role_admin') then
        create role role_admin nologin;
    end if;
end;
$$;


-- ============================================================
-- USERS (login roles)
-- ============================================================
do
$$
begin
    if not exists (select 1 from pg_roles where rolname = 'guest_user') then
        create role guest_user login password 'guest_123';
    end if;

    if not exists (select 1 from pg_roles where rolname = 'app_user') then
        create role app_user login password 'user_123';
    end if;

    if not exists (select 1 from pg_roles where rolname = 'manager_user') then
        create role manager_user login password 'manager_123';
    end if;

    if not exists (select 1 from pg_roles where rolname = 'admin_user') then
        create role admin_user login password 'admin_123';
    end if;
end;
$$;

grant role_guest   to guest_user;
grant role_user    to app_user;
grant role_manager to manager_user;
grant role_admin   to admin_user;


-- ============================================================
-- DB-LEVEL GRANTS
-- ============================================================
grant connect on database postgres
    to role_guest, role_user, role_manager, role_admin;


-- ============================================================
-- SCHEMA-LEVEL GRANTS
-- ============================================================
-- USAGE даёт видеть объекты схемы, но не даёт SELECT на таблицы
grant usage on schema app, profile, content, util, audit
    to role_guest, role_user, role_manager, role_admin;


-- ============================================================
-- UTIL FUNCTIONS
-- ============================================================
grant execute on function util.sanitize_text(text, text)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function util.is_record_active(text, uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function util.validate_exists_by_id(text, uuid)
    to role_guest, role_user, role_manager, role_admin;

-- soft-delete только для ролей, которые вообще могут мутировать данные
grant execute on function util.set_entity_lifecycle(text, uuid, boolean)
    to role_user, role_manager, role_admin;


-- ============================================================
-- FUNCTION-LEVEL GRANTS
-- ============================================================

-- ── app.roles ────────────────────────────────────────────────
-- guest=–, user=–, manager=R1,RM, admin=C,R1,RM,U,D
grant execute on function app.get_app_roles()
    to role_manager, role_admin;
grant execute on function app.get_app_role_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function app.create_app_role(varchar)
    to role_admin;
grant execute on function app.update_app_role_by_uuid(uuid, varchar)
    to role_admin;
grant execute on function app.delete_app_role_by_uuid(uuid)
    to role_admin;
grant execute on function app.restore_app_role_by_uuid(uuid)
    to role_admin;


-- ── profile.user_profiles ───────────────────────────────────
-- guest=–, user=R1 (свой профиль), manager=R1,RM, admin=C,R1,RM,U,D
grant execute on function profile.get_app_user_profiles()
    to role_manager, role_admin;
grant execute on function profile.get_app_user_profile_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function profile.create_app_user_profile(varchar, uuid)
    to role_admin;
grant execute on function profile.update_app_user_profile_by_uuid(uuid, varchar, uuid)
    to role_admin;
grant execute on function profile.delete_app_user_profile_by_uuid(uuid)
    to role_admin;
grant execute on function profile.restore_app_user_profile_by_uuid(uuid)
    to role_admin;

-- «свой профиль»
grant execute on function profile.get_own_app_user_profile(uuid)
    to role_user, role_manager, role_admin;


-- ── app.users ────────────────────────────────────────────────
-- guest=–, user=R1 (свой аккаунт), manager=–, admin=C,R1,RM,U,D
grant execute on function app.get_app_users()
    to role_admin;
grant execute on function app.get_app_user_by_uuid(uuid)
    to role_admin;

grant execute on function app.create_app_user(varchar, varchar, uuid)
    to role_admin;
grant execute on function app.update_app_user_by_uuid(uuid, varchar, varchar, uuid)
    to role_admin;
grant execute on function app.delete_app_user_by_uuid(uuid)
    to role_admin;
grant execute on function app.restore_app_user_by_uuid(uuid)
    to role_admin;

-- «свой пользователь»
grant execute on function app.get_own_app_user(uuid)
    to role_user;


-- ── content.brands ───────────────────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_brands()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_brand_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_brand(varchar)
    to role_manager, role_admin;
grant execute on function content.update_brand_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_brand_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_brand_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.drive_types ──────────────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_drive_types()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_drive_type_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_drive_type(varchar)
    to role_manager, role_admin;
grant execute on function content.update_drive_type_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_drive_type_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_drive_type_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.transmission_types ───────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_transmission_types()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_transmission_type_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_transmission_type(varchar)
    to role_manager, role_admin;
grant execute on function content.update_transmission_type_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_transmission_type_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_transmission_type_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.usage_types ──────────────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_usage_types()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_usage_type_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_usage_type(varchar)
    to role_manager, role_admin;
grant execute on function content.update_usage_type_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_usage_type_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_usage_type_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.capacity_types ───────────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_capacity_types()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_capacity_type_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_capacity_type(varchar)
    to role_manager, role_admin;
grant execute on function content.update_capacity_type_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_capacity_type_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_capacity_type_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.capacities ───────────────────────────────────────
-- guest=RM,R1, user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_capacities()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_capacity_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_capacity(int, uuid)
    to role_manager, role_admin;
grant execute on function content.update_capacity_by_uuid(uuid, int, uuid)
    to role_manager, role_admin;
grant execute on function content.delete_capacity_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_capacity_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.cars ─────────────────────────────────────────────
-- guest/user=RM,R1, manager/admin=C,R1,RM,U,D
grant execute on function content.get_cars()
    to role_guest, role_user, role_manager, role_admin;
grant execute on function content.get_car_by_uuid(uuid)
    to role_guest, role_user, role_manager, role_admin;

grant execute on function content.create_car(
    varchar, numeric, date, varchar, text,
    uuid, uuid, uuid, uuid, uuid
) to role_manager, role_admin;

grant execute on function content.update_car_by_uuid(
    uuid, varchar, numeric, date, varchar, text,
    uuid, uuid, uuid, uuid, uuid
) to role_manager, role_admin;

grant execute on function content.delete_car_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_car_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.requests ─────────────────────────────────────────
-- guest=–, user=C,R1,RM,U,D (свои), manager=C,R1,RM,U,D, admin=R1,RM
grant execute on function content.get_app_requests()
    to role_manager, role_admin;
grant execute on function content.get_app_request_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function content.create_app_request(uuid, uuid, text)
    to role_user, role_manager;

grant execute on function content.update_app_request_by_uuid(uuid, uuid, uuid, text)
    to role_manager;

grant execute on function content.delete_app_request_by_uuid(uuid)
    to role_manager;
grant execute on function content.restore_app_request_by_uuid(uuid)
    to role_manager;

-- «свои заявки»
grant execute on function content.get_own_app_requests(uuid)
    to role_user;
grant execute on function content.get_own_app_request_by_uuid(uuid, uuid)
    to role_user;


-- ── content.orders ───────────────────────────────────────────
-- guest=–, user=R1,RM (свои), manager=C,R1,RM,D, admin=R1,RM
grant execute on function content.get_app_orders()
    to role_manager, role_admin;
grant execute on function content.get_app_order_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function content.create_app_order(
    date, int, numeric, numeric, uuid, uuid, uuid, text
) to role_manager;

grant execute on function content.update_app_order_by_uuid(
    uuid, date, int, numeric, numeric, uuid, uuid, uuid, text
) to role_manager;

grant execute on function content.delete_app_order_by_uuid(uuid)
    to role_manager;
grant execute on function content.restore_app_order_by_uuid(uuid)
    to role_manager;

-- «свои договоры»
grant execute on function content.get_own_app_orders(uuid)
    to role_user;
grant execute on function content.get_own_app_order_by_uuid(uuid, uuid)
    to role_user;


-- ── content.statuses ─────────────────────────────────────────
-- guest=–, user=RM, manager/admin=C,R1,RM,U,D
grant execute on function content.get_app_statuses()
    to role_user, role_manager, role_admin;
grant execute on function content.get_app_status_by_uuid(uuid)
    to role_user, role_manager, role_admin;

grant execute on function content.create_app_status(varchar)
    to role_manager, role_admin;
grant execute on function content.update_app_status_by_uuid(uuid, varchar)
    to role_manager, role_admin;
grant execute on function content.delete_app_status_by_uuid(uuid)
    to role_manager, role_admin;
grant execute on function content.restore_app_status_by_uuid(uuid)
    to role_manager, role_admin;


-- ── content.request_status_histories ────────────────────────
-- guest=–, user=R1,RM (по своим), manager/admin=R1,RM + C, без U,D
grant execute on function content.get_app_request_status_histories()
    to role_manager, role_admin;
grant execute on function content.get_app_request_status_history_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function content.create_app_request_status_history(uuid, uuid)
    to role_manager, role_admin;

-- свои истории по заявкам
grant execute on function content.get_own_app_request_status_histories(uuid)
    to role_user;
grant execute on function content.get_own_app_request_status_histories_by_request(uuid, uuid)
    to role_user;


-- ── content.order_status_histories ──────────────────────────
-- guest=–, user=R1,RM (по своим), manager/admin=R1,RM + C, без U,D
grant execute on function content.get_app_order_status_histories()
    to role_manager, role_admin;
grant execute on function content.get_app_order_status_history_by_uuid(uuid)
    to role_manager, role_admin;

grant execute on function content.create_app_order_status_history(uuid, uuid)
    to role_manager, role_admin;

-- свои истории по договорам
grant execute on function content.get_own_app_order_status_histories(uuid)
    to role_user;
grant execute on function content.get_own_app_order_status_histories_by_order(uuid, uuid)
    to role_user;


-- ── audit.dml_logs ──────────────────────────────────────────
-- журнал аудита читает только admin
-- (через прямой SELECT, либо через обёртку, если добавишь функцию)
grant select on audit.dml_logs
    to role_admin;


-- ============================================================
-- TABLE-LEVEL GRANTS
-- ============================================================

-- ── SELECT ───────────────────────────────────────────────────
-- guest: только справочники и автомобили
grant select on
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars
to role_guest;

-- user: таблицы, с которыми он работает (профиль, свой user, свои заявки/договоры через функции)
grant select on
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_user;

-- manager: всё как у user + управление статусами
grant select on
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_manager;

-- admin: полный SELECT
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
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories,
    audit.dml_logs
to role_admin;


-- ── INSERT ───────────────────────────────────────────────────
-- guest не создаёт ничего

-- user: может создавать свои аккаунты и заявки
grant insert on
    app.users,
    content.requests
to role_user;

-- manager: создаёт справочники, авто, заявки, заказы, статусы, истории
grant insert on
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_manager;

-- admin: дополнительно roles
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
    content.requests,
    content.orders,
    content.statuses,
    content.request_status_histories,
    content.order_status_histories
to role_admin;


-- ── UPDATE ───────────────────────────────────────────────────
-- истории (request/order_status_histories) и dml_logs без UPDATE
-- orders обновляют только manager/admin на табличном уровне,
-- но бизнес-ограничение «не менять договор» можно держать во view/API.

grant update on
    profile.user_profiles,
    app.users,
    content.brands,
    content.drive_types,
    content.transmission_types,
    content.usage_types,
    content.capacity_types,
    content.capacities,
    content.cars,
    content.requests,
    content.orders,
    content.statuses
to role_manager;

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
    content.requests,
    content.orders,
    content.statuses
to role_admin;


-- ============================================================
-- SETUP-REPLICATION
-- ============================================================
-- ─── master ─────────────────────────────────────────────────
-- create role repl_user
--     with login replication password '111';

-- grant connect on database postgres to repl_user;

-- grant usage on schema app, profile, content, util, audit to repl_user;
-- grant select on all tables in schema app, profile, content, util, audit to repl_user;

-- alter default privileges in schema app, profile, content, util, audit
--     grant select on tables to repl_user;


-- create publication postgres_pub_all
--     for tables in schema app, profile, content, util, audit;


-- show wal_level;
-- alter system set wal_level = 'logical';
-- ─── slave-1 ──────────────────────────────────────────────────
-- create subscription postgres_sub_all_slave_1
--     connection 'host=postgres-master port=5432 dbname=postgres user=repl_user password=111'
--     publication postgres_pub_all
--     with (
--         copy_data = false,
--         enabled   = true
--     );


-- ─── slave-2 ──────────────────────────────────────────────────
-- create subscription postgres_sub_all_slave_2
--     connection 'host=postgres-master port=5432 dbname=postgres user=repl_user password=111'
--     publication postgres_pub_all
--     with (
--         copy_data = false,
--         enabled   = true
--     );


-- create table if not exists util.export_buffer (
--     id   serial primary key,
--     data text not null
-- );

-- create or replace procedure content.export_cars_to_json()
-- language plpgsql
-- as $$
-- begin
--     truncate table util.export_buffer;

--     insert into util.export_buffer(data)
--     select coalesce(
--                jsonb_agg(
--                    jsonb_build_object(
--                        'id', c.id,
--                        'name', c.name,
--                        'price_of_origin', c.price_of_origin,
--                        'manufacture_date', c.manufacture_date,
--                        'country_of_origin', c.country_of_origin,
--                        'description', c.description,
--                        'is_deleted', c.is_deleted,
--                        'brand_id', c.brand_id,
--                        'drive_type_id', c.drive_type_id,
--                        'transmission_type_id', c.transmission_type_id,
--                        'usage_type_id', c.usage_type_id,
--                        'capacity_id', c.capacity_id
--                    )
--                ),
--                '[]'::jsonb
--            )::text
--     from content.cars c
--     where c.is_deleted = false;
-- end;
-- $$;

-- create or replace procedure content.import_cars_from_json(p_file_path text)
-- language plpgsql
-- as $$
-- begin
--     create temp table if not exists tmp_json_import (
--         data jsonb
--     ) on commit drop;

--     truncate table tmp_json_import;

--     execute format(
--         'copy tmp_json_import(data) from %L',
--         p_file_path
--     );

--     if not exists (select 1 from tmp_json_import) then
--         raise exception 'Файл импорта пуст или не был загружен: %', p_file_path;
--     end if;

--     insert into content.cars (
--         name,
--         price_of_origin,
--         manufacture_date,
--         country_of_origin,
--         description,
--         brand_id,
--         drive_type_id,
--         transmission_type_id,
--         usage_type_id,
--         capacity_id
--     )
--     select
--         x.name,
--         x.price_of_origin,
--         x.manufacture_date,
--         x.country_of_origin,
--         x.description,
--         x.brand_id,
--         x.drive_type_id,
--         x.transmission_type_id,
--         x.usage_type_id,
--         x.capacity_id
--     from tmp_json_import t,
--          jsonb_to_recordset(t.data) as x(
--              name varchar(100),
--              price_of_origin numeric(12,2),
--              manufacture_date date,
--              country_of_origin varchar(100),
--              description text,
--              brand_id uuid,
--              drive_type_id uuid,
--              transmission_type_id uuid,
--              usage_type_id uuid,
--              capacity_id uuid
--          );
-- end;
-- $$;


-- call content.export_cars_to_json();
-- \copy (
--     select data from util.export_buffer
-- ) to '/var/lib/postgresql/18/docker/cars.json';
-- truncate table content.cars cascade;

-- select * from content.cars;
-- call content.import_cars_from_json('/var/lib/postgresql/18/docker/cars.json');

