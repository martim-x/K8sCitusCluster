-- warn
-- drop table if exists app_order_status_history cascade;
-- drop table if exists app_request_status_history cascade;
-- drop table if exists app_status cascade;

-- warn
-- drop table if exists profile_filter_brand cascade;
-- drop table if exists profile_filter_drive_type cascade;
-- drop table if exists profile_filter_transmission_type cascade;
-- drop table if exists profile_filter_usage_type cascade;
-- drop table if exists profile_filter_capacity cascade;

-- warn
-- drop table if exists car cascade;
-- drop table if exists car_passport cascade;
-- drop table if exists capacity cascade;
-- drop table if exists capacity_type cascade;
-- drop table if exists drive_type cascade;
-- drop table if exists transmission_type cascade;
-- drop table if exists usage_type cascade;
-- drop table if exists brand cascade;

-- warn
-- drop table if exists app_user cascade;
-- drop table if exists app_user_profile cascade;
-- drop table if exists app_role cascade;


-- ========================
-- USER
-- ========================

create table app_role (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table app_user_profile (
    id         uuid primary key default gen_random_uuid(),

    name       varchar(100) not null,
    is_deleted boolean not null default false,

    app_role_id uuid not null references app_role(id)
);

create table app_user (
    id                  uuid primary key default gen_random_uuid(),

    email               varchar(250) unique not null,
    password            varchar(128) not null,

    app_user_profile_id uuid not null references app_user_profile(id)
);

create table app_user_profile_car (
    id   uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),    
    car_id uuid not null references car(id)
)


-- ========================
-- CAR DICT
-- ========================

create table brand (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table drive_type (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table transmission_type (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table usage_type (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table capacity_type (
    id   uuid primary key default gen_random_uuid(),

    name varchar(100) not null
);

create table capacity (
    id              uuid primary key default gen_random_uuid(),

    value           int not null check (value > 0),

    capacity_type_id uuid not null references capacity_type(id)
);

-- ========================
-- USER'S FILTERS
-- ========================

create table profile_filter_brand (
    id                  uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),
    brand_id            uuid not null references brand(id)
);

create table profile_filter_drive_type (
    id                  uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),
    drive_type_id       uuid not null references drive_type(id)
);

create table profile_filter_transmission_type (
    id                  uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),
    transmission_type_id uuid not null references transmission_type(id)
);

create table profile_filter_usage_type (
    id                  uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),
    usage_type_id       uuid not null references usage_type(id)
);

create table profile_filter_capacity (
    id                  uuid primary key default gen_random_uuid(),

    app_user_profile_id uuid not null references app_user_profile(id),
    capacity_id         uuid not null references capacity(id)
);

-- ========================
-- CAR
-- ========================

create table car (
    id                  uuid primary key default gen_random_uuid(),

    name                varchar(100) not null,
    price_of_origin     numeric(12, 2) not null check (price_of_origin > 0),
    manufacture_date    date not null,
    country_of_origin   varchar(100) not null,
    description         text not null,

    is_deleted          boolean not null default false,

    brand_id            uuid not null references brand(id),
    drive_type_id       uuid not null references drive_type(id),
    transmission_type_id uuid not null references transmission_type(id),
    usage_type_id       uuid not null references usage_type(id),
    capacity_id         uuid not null references capacity(id)
);

-- ========================
-- APP_ORDER & APP_REQUEST
-- ========================

create table app_request (
    id          uuid primary key default gen_random_uuid(),

    app_user_id uuid not null references app_user(id),
    car_id      uuid not null references car(id),
    comment     text,

    is_deleted  boolean not null default false
);

create table app_order (
    id              uuid primary key default gen_random_uuid(),

    comment         text,
    order_date      date not null,
    period_months   int not null check (period_months > 0),
    down_payment    numeric(12, 2) not null check (down_payment > 0),
    monthly_payment numeric(12, 2) not null check (monthly_payment > 0),

    is_deleted      boolean not null default false,

    app_user_id     uuid not null references app_user(id),
    manager_id      uuid not null references app_user(id),
    app_request_id  uuid not null references app_request(id)
);

-- ========================
-- STATUS
-- ========================

create table app_status (
    id   uuid primary key default gen_random_uuid(),
    name varchar(100) not null
    -- 'REQUEST_PENDING', 'REQUEST_ACCEPTED', 'REQUEST_CANCELLED',
    -- 'ORDER_PENDING',   'ORDER_ACCEPTED',   'ORDER_CANCELLED'
);

-- ========================
-- STATUS HISTORY
-- ========================

create table app_request_status_history (
    id             uuid primary key default gen_random_uuid(),

    created_at     timestamptz not null default now(),

    app_status_id  uuid not null references app_status(id),
    app_request_id uuid not null references app_request(id)
);

create table app_order_status_history (
    id            uuid primary key default gen_random_uuid(),

    created_at    timestamptz not null default now(),

    app_status_id uuid not null references app_status(id),
    app_order_id  uuid not null references app_order(id)
);
