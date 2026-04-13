#db #postgres #plpgsql #schema #crud #roles #triggers #audit #docs
___
## Назначение документа

Документ описывает **физические объекты БД**, **логические правила работы**, **паттерны реализации CRUD**, **матрицу прав доступа** и **систему аудита** для файлов `init-db-schemas.sql` и `seed.sql`.

Под «**физическим объектом**» понимается схема, таблица, индекс, функция, триггер, роль, пользователь БД.  
Под «**логической конструкцией**» — soft delete через `is_deleted`, restore-on-conflict в `create_*`, append-only для историй статусов, валидация FK через `util.validate_exists_by_id(...)`, паттерн обработки ошибок, модель прав через роли и `GRANT EXECUTE` на функции, DML-аудит через триггеры.


___
## Структура схем

| Схема      | Назначение                                                      |
|------------|-----------------------------------------------------------------|
| `app`      | Роли приложения и пользователи (учётные данные)                 |
| `profile`  | Профили пользователей (связь user ↔ role)                       |
| `content`  | Справочники, автомобили, заявки, заказы, статусы и их истории   |
| `junction` | Связующие таблицы (профиль ↔ авто, фильтры профиля)            |
| `util`     | Вспомогательные функции (sanitize, validate, lifecycle)         |
| `audit`    | Логирование DML-операций                                        |


___
## Статистика файла init-db-schemas.sql

| Показатель                                        | Значение                       |
|---------------------------------------------------|--------------------------------|
| Схем                                              | 6 (`app/profile/content/junction/util/audit`) |
| Таблиц                                            | 22 (21 рабочих + `audit.dml_logs`) |
| Util-функций                                      | 4                              |
| CRUD-функций (`create/get/update/delete/restore`) | 114                            |
| Триггеров                                         | 21 (по одному на каждую рабочую таблицу) |
| Ролей                                             | 4 (`guest/user/manager/admin`) |
| Пользователей БД                                  | 4 (`usr_guest/usr_user/usr_manager/usr_admin`) |
| Hash-индексов по `id`                             | 21 (по 1 на таблицу) + 4 на `audit.dml_logs` |


___
## Реестр таблиц БД

| Таблица                                   | Схема      | Группа      | Ключевые поля / особенности                                               |
|-------------------------------------------|------------|-------------|---------------------------------------------------------------------------|
| `roles`                                   | `app`      | USER        | `id`, `name unique`, `is_deleted`                                         |
| `user_profiles`                           | `profile`  | USER        | `id`, `name`, `app_role_id FK`, `is_deleted`                              |
| `users`                                   | `app`      | USER        | `id`, `email unique`, `password`, `app_user_profile_id FK`, `is_deleted`  |
| `brands`                                  | `content`  | CAR DICT    | `id`, `name unique`, `is_deleted`                                         |
| `drive_types`                             | `content`  | CAR DICT    | `id`, `name unique`, `is_deleted`                                         |
| `transmission_types`                      | `content`  | CAR DICT    | `id`, `name unique`, `is_deleted`                                         |
| `usage_types`                             | `content`  | CAR DICT    | `id`, `name unique`, `is_deleted`                                         |
| `capacity_types`                          | `content`  | CAR DICT    | `id`, `name unique`, `is_deleted`                                         |
| `capacities`                              | `content`  | CAR DICT    | `id`, `value > 0`, `capacity_type_id FK`, `is_deleted`                    |
| `cars`                                    | `content`  | CAR         | `id`, скалярные поля + FK на все car-справочники, `is_deleted`            |
| `user_profile_cars`                       | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `car_id FK`, `is_deleted`                 |
| `profile_filter_brands`                   | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `brand_id FK`, `is_deleted`               |
| `profile_filter_drive_types`              | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `drive_type_id FK`, `is_deleted`          |
| `profile_filter_transmission_types`       | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `transmission_type_id FK`, `is_deleted`   |
| `profile_filter_usage_types`              | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `usage_type_id FK`, `is_deleted`          |
| `profile_filter_capacities`               | `junction` | JUNCTION    | `id`, `app_user_profile_id FK`, `capacity_id FK`, `is_deleted`            |
| `requests`                                | `content`  | REQUEST     | `id`, `comment nullable`, `app_user_id FK`, `car_id FK`, `is_deleted`     |
| `orders`                                  | `content`  | ORDER       | `id`, финансовые поля, `app_user_id FK`, `manager_id FK`, `app_request_id FK`, `comment nullable`, `is_deleted` |
| `statuses`                                | `content`  | STATUS      | `id`, `name unique`, `is_deleted`                                         |
| `request_status_histories`                | `content`  | STATUS HIST | `id`, `created_at`, `app_status_id FK`, `app_request_id FK`, `is_deleted` |
| `order_status_histories`                  | `content`  | STATUS HIST | `id`, `created_at`, `app_status_id FK`, `app_order_id FK`, `is_deleted`   |
| `dml_logs`                                | `audit`    | AUDIT       | `id bigserial`, `role_name`, `table_schema`, `table_name`, `dml_operation`, `occurred_at` |


___
## Util-функции (`util`-схема)

### Обзор util-слоя

| Функция                                        | Назначение                                                     |
|------------------------------------------------|----------------------------------------------------------------|
| `util.sanitize_text(text, text)`               | Санитизация строковых входов (trim + empty check)              |
| `util.is_record_active(text, uuid)`            | Проверка существования записи с учётом `is_deleted`            |
| `util.validate_exists_by_id(text, uuid)`       | Жёсткая валидация FK — бросает exception при отсутствии записи |
| `util.set_entity_lifecycle(text, uuid, bool)`  | Универсальный переключатель soft delete / restore              |

Все четыре функции принимают имя таблицы в формате `'schema.table'` (например `'content.cars'`) и корректно разбирают схему через `string_to_array(p_table_name, '.')`.

### util.sanitize_text

`sanitize_text(p_value text, p_field_name text default 'field') returns text` — выполняет `trim(p_value)`, затем проверяет результат на `null` / `''` и выбрасывает исключение с именем поля.  
Используется в `create_*` / `update_*` для всех `varchar` / `text` полей, кроме `password` (trim намеренно не применяется к хэшам).

### util.is_record_active

`is_record_active(p_table_name text, p_id uuid) returns boolean` — динамически проверяет наличие строки по `id`.  
Разбирает `schema.table`, запрашивает `information_schema.columns` на наличие колонки `is_deleted`, и выполняет соответствующий `SELECT`. В случае ошибки возвращает `false`.

### util.validate_exists_by_id

`validate_exists_by_id(p_table_name text, p_id uuid) returns void` — обёртка над `is_record_active`, которая бросает exception если запись не найдена или soft-deleted.  
Вызывается через `perform` перед каждым `INSERT`/`UPDATE` с FK.

### util.set_entity_lifecycle

`set_entity_lifecycle(p_table_name text, p_id uuid, p_is_deleted boolean) returns uuid` — выполняет динамический `UPDATE ... SET is_deleted = $1 WHERE id = $2 RETURNING id` с поддержкой формата `schema.table`.  
Все `delete_*` / `restore_*` — тонкие обёртки над этой функцией.


___
## Модель ключей и индексов

### Первичные ключи

Все таблицы используют `uuidv7()`:

- `id uuid primary key default uuidv7()` — во всех 22 (21 рабочих + `audit.dml_logs`) таблицах.
- UUIDv7 монотонно возрастает, что оптимизирует B-tree вставки и снижает фрагментацию страниц.

### Hash-индексы

Для каждой рабочей таблицы создан дополнительный hash-индекс по `id`:

- `create index idx_<entity>_id_hash on <schema>.<table> using hash (id);`
- В итоге на `id` два индекса: PK (B-tree) — для FK и диапазонных операций; Hash — для точечных `WHERE id = $1`.

### Индексы audit.dml_logs

На таблице `audit.dml_logs` созданы 4 индекса для эффективной фильтрации логов:

| Индекс                   | Поле(я)                      |
|--------------------------|------------------------------|
| `idx_dml_logs_role`      | `role_name`                  |
| `idx_dml_logs_table`     | `table_schema, table_name`   |
| `idx_dml_logs_operation` | `dml_operation`              |
| `idx_dml_logs_time`      | `occurred_at DESC`           |


___
## Паттерн удаления (soft delete)

### Поле is_deleted

- Во всех рабочих таблицах: `is_deleted boolean not null default false`.
- Физическое удаление строк не используется.

### Обёртки delete/restore

- `delete_<entity>_by_uuid(p_id uuid)` → `util.set_entity_lifecycle('schema.table', p_id, true)`.
- `restore_<entity>_by_uuid(p_id uuid)` → `util.set_entity_lifecycle('schema.table', p_id, false)`.

### Append-only сущности

- `content.request_status_histories`
- `content.order_status_histories`

Для них реализованы только `create_*`, `get_*`, `get_*_by_uuid`. Функций `update_*`, `delete_*`, `restore_*` **нет**.


___
## CRUD-покрытие по таблицам

| Таблица                           | Схема      | create | get many | get 1 | update | delete | restore |
|-----------------------------------|------------|--------|----------|-------|--------|--------|---------|
| `roles`                           | `app`      | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `user_profiles`                   | `profile`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `users`                           | `app`      | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `brands`                          | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `drive_types`                     | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `transmission_types`              | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `usage_types`                     | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `capacity_types`                  | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `capacities`                      | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `cars`                            | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `user_profile_cars`               | `junction` | ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `profile_filter_brands`           | `junction` | ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `profile_filter_drive_types`      | `junction` | ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `profile_filter_transmission_types`| `junction`| ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `profile_filter_usage_types`      | `junction` | ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `profile_filter_capacities`       | `junction` | ✅      | ✅        | ✅     | ❌      | ✅      | ✅       |
| `requests`                        | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `orders`                          | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `statuses`                        | `content`  | ✅      | ✅        | ✅     | ✅      | ✅      | ✅       |
| `request_status_histories`        | `content`  | ✅      | ✅        | ✅     | ❌      | ❌      | ❌       |
| `order_status_histories`          | `content`  | ✅      | ✅        | ✅     | ❌      | ❌      | ❌       |


___
## Паттерн restore-on-conflict

В `create_*` для следующих сущностей реализован шаблон:

1. Поиск soft-deleted записи по бизнес-ключу.
2. Если найдена — восстановление (через `util.set_entity_lifecycle` или локальный `UPDATE`).
3. Если нет — обычный `INSERT`.

| Таблица                                     | Схема      | Бизнес-ключ                                |
|---------------------------------------------|------------|--------------------------------------------|
| `roles`                                     | `app`      | `name`                                     |
| `user_profiles`                             | `profile`  | `name`                                     |
| `users`                                     | `app`      | `email`                                    |
| `brands`                                    | `content`  | `name`                                     |
| `drive_types`                               | `content`  | `name`                                     |
| `transmission_types`                        | `content`  | `name`                                     |
| `usage_types`                               | `content`  | `name`                                     |
| `capacity_types`                            | `content`  | `name`                                     |
| `statuses`                                  | `content`  | `name`                                     |
| `capacities`                                | `content`  | `value + capacity_type_id`                 |
| `user_profile_cars`                         | `junction` | `app_user_profile_id + car_id`             |
| `profile_filter_brands`                     | `junction` | `app_user_profile_id + brand_id`           |
| `profile_filter_drive_types`                | `junction` | `app_user_profile_id + drive_type_id`      |
| `profile_filter_transmission_types`         | `junction` | `app_user_profile_id + transmission_type_id` |
| `profile_filter_usage_types`                | `junction` | `app_user_profile_id + usage_type_id`      |
| `profile_filter_capacities`                 | `junction` | `app_user_profile_id + capacity_id`        |


___
## Обработка ошибок в CRUD

- Функции, возвращающие `uuid` или запись: `exception when others then return null;`
- Функции, возвращающие `setof <table>`: `exception when others then return;` (пустой набор)

Исключения специально используются только:
- в `util.sanitize_text(...)` — для пустых строк,
- в `util.validate_exists_by_id(...)` — для отсутствующих FK.


___
## Система аудита (audit-схема)

### Таблица audit.dml_logs

| Колонка        | Тип          | Описание                              |
|----------------|--------------|---------------------------------------|
| `id`           | `uuid`       |  PK                   |
| `role_name`    | `text`       | Имя DB-роли (`current_user`)          |
| `table_schema` | `text`       | Схема таблицы (`tg_table_schema`)     |
| `table_name`   | `text`       | Имя таблицы (`tg_table_name`)         |
| `dml_operation`| `text`       | Операция: `INSERT`, `UPDATE`, `DELETE`|
| `occurred_at`  | `timestamptz`| Время операции (`now()`)              |

### Триггерная функция audit.log_dml_operation

- Объявлена с `SECURITY DEFINER` — выполняется от имени владельца схемы, поэтому любая роль через эту функцию может писать в `audit.dml_logs`, даже не имея прямого `INSERT` на таблицу.
- Возвращает `null` (допустимо для `AFTER`-триггеров).

### Установка триггеров

Для каждой из 21 рабочих таблиц через `audit.attach_dml_trigger(schema, table)` создаётся триггер:

```sql
create trigger trg_audit_dml__<schema>__<table>
after insert or update or delete
on <schema>.<table>
for each row execute function audit.log_dml_operation();
```

### Права на audit

- `role_admin` — единственная роль с прямым `SELECT` на `audit.dml_logs`.
- Остальные роли не видят таблицу напрямую.


___
## Модель прав (логический уровень)

### Роли и пользователи БД

Определены 4 роли (`nologin`) и 4 пользователя (`noinherit`) — каждый пользователь привязан к своей роли через `GRANT ROLE TO USER`.

| Роль           | Пользователь   | Пароль |
|----------------|----------------|--------|
| `role_guest`   | `usr_guest`    | `111`  |
| `role_user`    | `usr_user`     | `111`  |
| `role_manager` | `usr_manager`  | `111`  |
| `role_admin`   | `usr_admin`    | `111`  |

`noinherit` означает, что пользователь **не** наследует права роли автоматически — он должен явно выполнить `SET ROLE role_xxx` внутри сессии. Это снижает риск случайного превышения прав.

### Права выполнения функций (GRANT EXECUTE)

| Сущность / группа функций          | guest | user  | manager | admin |
|------------------------------------|-------|-------|---------|-------|
| `util.*`                           | R     | R     | R       | R     |
| `util.set_entity_lifecycle`        | —     | R     | R       | R     |
| `app.roles`                        | —     | —     | —       | R/C/U/D |
| `profile.user_profiles`            | —     | R/C/U | R/C/U   | R/C/U/D |
| `app.users`                        | —     | R/C/U | R/C/U   | R/C/U/D |
| CAR DICT (`brands`, `drive_types`, etc.) | R | R  | R       | R/C/U/D |
| `content.cars`                     | R     | R     | R       | R/C/U/D |
| `junction.user_profile_cars`       | —     | R/C/D | R/C/D   | R/C/D |
| `junction.profile_filter_*`        | —     | R/C/D | R/C/D   | R/C/D |
| `content.requests`                 | —     | R/C   | R/C/U/D | R/C/U/D |
| `content.orders`                   | —     | R     | R/C/U   | R/C/U/D |
| `content.statuses`                 | —     | —     | R       | R/C/U/D |
| `content.*_status_histories`       | —     | R     | R/C     | R/C   |
| `audit.dml_logs`                   | —     | —     | —       | R     |

Где: `R` — get/get_by_uuid, `C` — create, `U` — update, `D` — delete/restore.


___
## Файл seed.sql

### Назначение

`seed.sql` — файл начальных данных для ручного запуска после `init-db-schemas.sql`. Содержит INSERT-ы в правильном порядке с учётом FK-зависимостей.

### Почему не хранимая процедура для импорта

В PostgreSQL нельзя читать файлы с диска клиента средствами PL/pgSQL — `COPY FROM` работает только с серверным путём. Поэтому данные оформлены как готовый `.sql`-файл, который запускается вручную (`psql -f seed.sql`) или через бэкенд-инструмент.

### Порядок вставки в seed.sql

```
app.roles
  └─ profile.user_profiles
       └─ app.users
content.brands
content.drive_types
content.transmission_types
content.usage_types
content.capacity_types
  └─ content.capacities
       └─ content.cars
content.statuses
```

### UUID в seed.sql


Все UUID в seed-файле представлены в формате UUIDv7 (RFC 9562, time-ordered). Это обеспечивает:

- сортировку идентификаторов по времени генерации,
- равномерное распределение значений в B-tree индексах при вставках,
- совместимость с распределённой генерацией UUID без координации.

### Содержимое seed.sql

| Таблица                     | Записей |
|-----------------------------|---------|
| `app.roles`                 | 4       |
| `profile.user_profiles`     | 4       |
| `app.users`                 | 4       |
| `content.brands`            | 20      |
| `content.drive_types`       | 4       |
| `content.transmission_types`| 2       |
| `content.usage_types`       | 11      |
| `content.capacity_types`    | 2       |
| `content.capacities`        | 31      |
| `content.cars`              | 63      |
| `content.statuses`          | 8       |
