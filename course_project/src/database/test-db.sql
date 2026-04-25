-- ============================================================
-- TEST-INDEX
-- ============================================================
create or replace function util.generate_test_orders(p_orders_count integer default 100000)
returns void
language plpgsql
as $$
declare
    v_user_id        uuid := '019d85d4-098d-7a45-871a-692989d8c45b';  -- user@example.com
    v_manager_id     uuid := '019d85d4-098d-7fbf-80a7-81ce856f591d';  -- manager@example.com
    v_base_date      date := date '2024-01-01';
    v_car_ids        uuid[];
    v_req_id         uuid;
    v_order_id       uuid;
    v_app_status_new_id uuid;
    v_app_status_order_created_id uuid;
    i                integer;
begin
    -- список машин
    select array_agg(id) into v_car_ids
    from content.cars;

    if v_car_ids is null or array_length(v_car_ids, 1) = 0 then
        raise exception 'Нет машин в content.cars, генерировать заказы нельзя';
    end if;

    -- статусы
    select id into v_app_status_new_id
    from content.statuses
    where name = 'REQUEST_NEW';

    select id into v_app_status_order_created_id
    from content.statuses
    where name = 'ORDER_CREATED';

    if v_app_status_new_id is null or v_app_status_order_created_id is null then
        raise exception 'Не найдены статусы REQUEST_NEW или ORDER_CREATED в content.statuses';
    end if;

    -- основной цикл
    for i in 1..p_orders_count loop
        -- заявка
        v_req_id := gen_random_uuid();

        insert into content.requests (id, comment, app_user_id, car_id)
        values (
            v_req_id,
            format('Автоматически сгенерированная заявка %s', i),
            v_user_id,
            v_car_ids[1 + (random() * (array_length(v_car_ids, 1) - 1))::int]
        );

        -- история заявки
        insert into content.request_status_histories (id, created_at, app_status_id, app_request_id)
        values (
            gen_random_uuid(),
            now() - (random() * interval '60 days'),
            v_app_status_new_id,
            v_req_id
        );

        -- заказ
        v_order_id := gen_random_uuid();

        insert into content.orders (
            id,
            comment,
            order_date,
            period_months,
            down_payment,
            monthly_payment,
            app_user_id,
            manager_id,
            app_request_id
        )
        values (
            v_order_id,
            format('Автоматически сгенерированный заказ %s', i),
            v_base_date
                + ((random() * 365.0)::int)      -- разброс по году
                - ((random() * 30.0)::int),      -- ± немного дней
            6 + (random() * 48)::int,            -- 6–54 месяцев
            round((1000 + random() * 9000)::numeric, 2),   -- взнос 1k–10k
            round((200 + random() * 1800)::numeric, 2),    -- платёж 200–2000
            v_user_id,
            v_manager_id,
            v_req_id
        );

        -- история заказа
        insert into content.order_status_histories (id, created_at, app_status_id, app_order_id)
        values (
            gen_random_uuid(),
            now() - (random() * interval '60 days'),
            v_app_status_order_created_id,
            v_order_id
        );
    end loop;
end;
$$;



create index idx_orders_app_user_date_btree
    on content.orders (app_user_id, order_date);
select util.generate_test_orders(100000);  

explain analyze
select *
from content.orders o
where o.app_user_id = '019d85d4-098d-7a45-871a-692989d8c45b'
  and o.order_date = date '2024-06-15';
