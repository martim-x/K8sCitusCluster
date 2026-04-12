#db #postgres #plpgsql #schema #crud #roles #docs
___
## Назначение документа

Документ описывает _**физические объекты БД**_, _**логические правила работы**_, _**паттерны реализации CRUD**_ и _**матрицу прав доступа**_ для файла `init-db.sql`.

Под «_**физическим объектом**_» здесь понимается таблица, индекс, функция, роль.  
Под «_**логической конструкцией**_» — soft delete через `is_deleted`, restore-on-conflict в `create_*`, append-only для историй статусов, валидация FK через `validate_exists_by_id(...)`, паттерн обработки ошибок, модель прав через роли и `GRANT EXECUTE` на функции.


___
## Статистика файла init-db.sql

| Показатель                                    | Значение            |
|-----------------------------------------------|---------------------|
| Таблиц                                        | 21                  |
| Util-функций                                  | 4                   |
| Всего функций (включая util и CRUD)           | 118                 |
| CRUD-функций (`create/get/update/delete/restore`) | 114             |
| Ролей                                         | 4 (`guest/user/manager/admin`) |
| Hash-индексов по `id`                         | 21 (по 1 на таблицу)|


___
## Реестр таблиц БД

| Таблица                           | Группа         | Ключевые поля / особенности                            |
|-----------------------------------|----------------|--------------------------------------------------------|
| app_roles                         | USER           | `id`, `name unique`, `is_deleted`                      |
| app_user_profiles                 | USER           | `id`, `name`, `app_role_id FK`, `is_deleted`          |
| app_users                         | USER           | `id`, `email unique`, `password`, `app_user_profile_id FK`, `is_deleted` |
| brands                            | CAR DICT       | `id`, `name unique`, `is_deleted`                      |
| drive_types                       | CAR DICT       | `id`, `name unique`, `is_deleted`                      |
| transmission_types                | CAR DICT       | `id`, `name unique`, `is_deleted`                      |
| usage_types                       | CAR DICT       | `id`, `name unique`, `is_deleted`                      |
| capacity_types                    | CAR DICT       | `id`, `name unique`, `is_deleted`                      |
| capacities                        | CAR DICT       | `id`, `value > 0`, `capacity_type_id FK`, `is_deleted` |
| cars                              | CAR            | `id`, скалярные поля + FK на все car-справочники, `is_deleted` |
| app_user_profile_cars             | JUNCTION       | `id`, `app_user_profile_id FK`, `car_id FK`, `is_deleted` |
| profile_filter_brands             | JUNCTION       | `id`, `app_user_profile_id FK`, `brand_id FK`, `is_deleted` |
| profile_filter_drive_types        | JUNCTION       | `id`, `app_user_profile_id FK`, `drive_type_id FK`, `is_deleted` |
| profile_filter_transmission_types | JUNCTION       | `id`, `app_user_profile_id FK`, `transmission_type_id FK`, `is_deleted` |
| profile_filter_usage_types        | JUNCTION       | `id`, `app_user_profile_id FK`, `usage_type_id FK`, `is_deleted` |
| profile_filter_capacities         | JUNCTION       | `id`, `app_user_profile_id FK`, `capacity_id FK`, `is_deleted` |
| app_requests                      | REQUEST        | `id`, `comment nullable`, `app_user_id FK`, `car_id FK`, `is_deleted` |
| app_orders                        | ORDER          | `id`, финансовые поля, `app_user_id FK`, `manager_id FK`, `app_request_id FK`, `comment nullable`, `is_deleted` |
| app_statuses                      | STATUS         | `id`, `name unique`, `is_deleted`                      |
| app_request_status_histories      | STATUS HIST    | `id`, `created_at`, `app_status_id FK`, `app_request_id FK`, `is_deleted` |
| app_order_status_histories        | STATUS HIST    | `id`, `created_at`, `app_status_id FK`, `app_order_id FK`, `is_deleted` |


___
## Util-функции

### Обзор util-слоя

| Функция                                   | Назначение логическое                                  |
|-------------------------------------------|--------------------------------------------------------|
| `sanitize_text(text, text)`               | Санитизация строковых входов                           |
| `is_record_active(text, uuid)`           | Проверка существования записи (с учётом `is_deleted`)  |
| `validate_exists_by_id(text, uuid)`       | Жёсткая валидация FK с исключением                     |
| `set_entity_lifecycle(text, uuid, bool)`  | Универсальный переключатель soft delete / restore      |


### sanitize_text

Функция `sanitize_text(p_value text, p_field_name text default 'field') returns text` выполняет `trim(p_value)`, затем проверяет результат на `null` и `''` и в таких случаях выбрасывает исключение с именем поля.  
Используется в `create_*` / `update_*` для всех `varchar` / `text` полей, кроме `password`, где `trim()` намеренно не применяется.

### is_record_active

Функция `is_record_active(p_table_name text, p_id uuid) returns boolean` динамически проверяет наличие строки по `id`.  
Если у таблицы есть колонка `is_deleted`, проверка выполняется по `id = $1 and is_deleted = false`, если нет — по `id = $1`. В случае ошибки возвращает `false`, не пробрасывая исключение.

### validate_exists_by_id

Функция `validate_exists_by_id(p_table_name text, p_id uuid) returns void` использует `is_record_active(...)` и выбрасывает исключение, если запись не найдена или помечена как удалённая.  
Вызывается через `perform` перед каждым `INSERT`/`UPDATE` с FK, тем самым инкапсулируя проверку ссылочной целостности в отдельный util-слой.

### set_entity_lifecycle

Функция `set_entity_lifecycle(p_table_name text, p_id uuid, p_is_deleted boolean) returns uuid` выполняет динамический `update <table> set is_deleted = $1 where id = $2 returning id`.  
Все `delete_*_by_uuid(...)` / `restore_*_by_uuid(...)` реализованы как тонкие обёртки над этой функцией.


___
## Модель ключей и индексов

### Первичные ключи

Все таблицы используют `_**uuidv7()**_`:

- `id uuid primary key default uuidv7()` — во всех 21 таблице.
- Это даёт монотонно возрастающий UUID v7, оптимальный для B-tree по вставкам (без сильной фрагментации страниц).

### Hash-индексы

Для каждой таблицы создан дополнительный hash-индекс:

- Вид: `create index idx_<table>_id_hash on <table> using hash (id);`
- В итоге на `id` в каждой таблице два индекса:
  - PK (B-tree) — для FK и диапазонных операций.
  - Hash — для точечных `WHERE id = ...`.

Замечание: тезис «hash-индекс ускоряет `WHERE id = $1`» — _эмпирический_/архитектурный, а не факт SQL-файла; файл лишь фиксирует наличие индекса.


___
## Паттерн удаления (soft delete)

### Поле is_deleted

- Во всех таблицах присутствует `is_deleted boolean not null default false`.
- Это структурный стандарт схемы, но **не у всех сущностей** есть публичные функции `delete_*`/`restore_*` (истории статусов — append-only).

### Обёртки delete/restore

- `delete_<entity>_by_uuid(p_id uuid)` → `set_entity_lifecycle('<entity>', p_id, true)`.
- `restore_<entity>_by_uuid(p_id uuid)` → `set_entity_lifecycle('<entity>', p_id, false)`.

### Append-only сущности

- `app_request_status_histories`
- `app_order_status_histories`

Для них в коде присутствуют только:

- `create_app_request_status_history(...)`, `get_app_request_status_histories()`, `get_app_request_status_history_by_uuid(...)`
- `create_app_order_status_history(...)`, `get_app_order_status_histories()`, `get_app_order_status_history_by_uuid(...)`

Функций `update_*`, `delete_*`, `restore_*` **нет** — это и есть паттерн append-only.


___
## CRUD-покрытие по таблицам

### Таблица покрытия (по реальным функциям)

| Таблица                           | create | get many | get 1 (by_uuid) | update | delete | restore |
|-----------------------------------|--------|----------|-----------------|--------|--------|---------|
| app_roles                         | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_user_profiles                 | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_users                         | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| brands                            | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| drive_types                       | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| transmission_types                | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| usage_types                       | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| capacity_types                    | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| capacities                        | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| cars                              | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_user_profile_cars             | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| profile_filter_brands             | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| profile_filter_drive_types        | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| profile_filter_transmission_types | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| profile_filter_usage_types        | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| profile_filter_capacities         | ✅      | ✅        | ✅               | ❌      | ✅      | ✅       |
| app_requests                      | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_orders                        | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_statuses                      | ✅      | ✅        | ✅               | ✅      | ✅      | ✅       |
| app_request_status_histories      | ✅      | ✅        | ✅               | ❌      | ❌      | ❌       |
| app_order_status_histories        | ✅      | ✅        | ✅               | ❌      | ❌      | ❌       |


___
## Паттерн restore-on-conflict

### Сущности с restore-on-conflict в create_*

| Таблица                          | Бизнес-ключ                       |
|----------------------------------|-----------------------------------|
| app_roles                        | `name`                            |
| app_user_profiles                | `name`                            |
| app_users                        | `email`                           |
| brands                           | `name`                            |
| drive_types                      | `name`                            |
| transmission_types               | `name`                            |
| usage_types                      | `name`                            |
| capacity_types                   | `name`                            |
| app_statuses                     | `name`                            |
| capacities                       | `value + capacity_type_id`        |
| app_user_profile_cars            | `app_user_profile_id + car_id`    |
| profile_filter_brands            | `app_user_profile_id + brand_id`  |
| profile_filter_drive_types       | `app_user_profile_id + drive_type_id` |
| profile_filter_transmission_types| `app_user_profile_id + transmission_type_id` |
| profile_filter_usage_types       | `app_user_profile_id + usage_type_id` |
| profile_filter_capacities        | `app_user_profile_id + capacity_id` |

Во всех этих `create_*` реализован шаблон:

1. Поиск soft-deleted записи по бизнес-ключу.
2. Если найдена — восстановление (через `set_entity_lifecycle` или локальный `update` + `is_deleted=false`).
3. Если нет — обычный `insert`.


___
## Обработка ошибок в CRUD

- В `create_*`, `update_*`, `delete_*`, `restore_*`:

  - Для функций, возвращающих `uuid` или запись:  
    `exception when others then return null;`
  - Для функций, возвращающих `setof <table>`:  
    `exception when others then return;` (пустой набор).

- Исключения специально используются только:
  - внутри `sanitize_text(...)` для пустых строк,
  - внутри `validate_exists_by_id(...)` для отсутствующих FK.

Таким образом, внешний API функций стабилен по контракту: ошибки валятся наружу либо как `null`/пустой `set`, либо как предсказуемое исключение в точках валидации.


___
## Логические группы таблиц

### USER

- `app_roles` — роли приложения.
- `app_user_profiles` — профили пользователей, каждая строка привязана к `app_roles`.
- `app_users` — учётные данные (email/password) + FK на профиль.

### CAR DICT

- Простые справочники: `brands`, `drive_types`, `transmission_types`, `usage_types`, `capacity_types` — одинаковая структура `id + name + is_deleted`.
- Составной справочник: `capacities` (`value`, `capacity_type_id`).

### CAR

- `cars` — агрегирует все характеристики авто через FK на car-справочники и содержит основные атрибуты.

### JUNCTION

- `app_user_profile_cars` — связь профиля пользователя и машины.
- `profile_filter_*` — фильтры профиля по бренду/приводу/КПП/эксплуатации/ёмкости.

### REQUEST / ORDER

- `app_requests` — заявки пользователей на автомобили.
- `app_orders` — заказы по заявкам, с менеджером и финансовыми параметрами.

### STATUS / STATUS HIST

- `app_statuses` — справочник статусов (`REQUEST_*`, `ORDER_*`).
- `app_request_status_histories`, `app_order_status_histories` — истории смены статусов с `created_at` и append-only CRUD.


___
## Модель прав (логический уровень)

### Роли

Определены 4 роли без логина:

- `role_guest`
- `role_user`
- `role_manager`
- `role_admin`

### Права выполнения функций (GRANT EXECUTE)

Документ трактует матрицу прав как **права на выполнение CRUD-/util-функций**, а не как прямые `GRANT SELECT/INSERT/UPDATE` на таблицы.

Пример фрагмента матрицы (логический уровень):

| Сущность / группа функций        | guest | user | manager | admin |
|----------------------------------|-------|------|---------|-------|
| Util (`sanitize_*`, `validate_*`) | R     | R    | R       | R     |
| CRUD `app_roles`                 | —     | —    | —       | R/C/U/D |
| CRUD `app_user_profiles`         | —     | R/C/U| R/C/U   | R/C/U/D |
| CRUD `app_users`                 | —     | R/C/U| R/C/U   | R/C/U/D |
| CRUD справочники CAR DICT        | R     | R    | R       | R/C/U/D |
| CRUD `cars`                      | R     | R    | R       | R/C/U/D |
| CRUD `app_user_profile_cars`     | —     | R/C/D| R/C/D   | R/C/U/D |
| CRUD `profile_filter_*`          | —     | R/C/D| R/C/D   | R/C/U/D |
| CRUD `app_requests`              | —     | R/C  | R/C/U/D | R/C/U/D |
| CRUD `app_orders`                | —     | R    | R/C/U   | R/C/U/D |
| CRUD `app_statuses`              | —     | —    | R       | R/C/U/D |
| CRUD истории статусов            | —     | R    | R/C     | R/C     |

Где:

- `R` — право вызывать `get_*` / `get_*_by_uuid`.
- `C` — `create_*`.
- `U` — `update_*`.
- `D` — `delete_*` / `restore_*` (там, где они есть).
- `—` — вызов соответствующих функций роли недоступен.