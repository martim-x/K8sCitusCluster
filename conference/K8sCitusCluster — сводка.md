#k8s #citus #postgresql #helm #statefulset #репликация #pg-locker
___
## Что за проект

Проект реализует полностью автоматизированный распределённый кластер _**PostgreSQL + Citus**_ внутри Kubernetes, упакованный в Helm Chart. Разворачивается одной командой `helm install` и управляется через единый файл `values.yaml`.


___
## Архитектура кластера

Три уровня компонентов, каждый со своей ролью:

```
Уровень 1: 3× PostgreSQL Masters   (postgres:18.3)
           ↕ двусторонняя логическая репликация
Уровень 2: 3× Citus Coordinators   (citusdata/citus:13.0)
           ↕ регистрация воркеров через citus_add_node()
Уровень 3: 9× Citus Workers        (3 на каждый coordinator)

Отдельно:  1× pg-locker            (postgres:18.3)
```

Мастера хранят «сырые» данные и синхронизируются между собой. Координаторы управляют шардированием через Citus. Воркеры хранят шарды. pg-locker — централизованный сервер блокировок.


___
## Почему StatefulSet, а не Deployment

#statefulset
StatefulSet выбран для _**всех**_ компонентов по трём причинам:

1. Стабильные DNS-имена — под `master-1` всегда доступен как `master-1.citus.svc.cluster.local`. PostgreSQL-репликация настраивается по hostname: смена имени = разрыв репликации.
2. PVC не теряются при перезапуске — данные сохраняются, слоты репликации не нужно пересоздавать.
3. Предсказуемый порядок создания/удаления подов.

`Deployment` при пересоздании пода даёт случайный суффикс и случайный PVC — это убивает PostgreSQL-репликацию.


___
## Настройка WAL для логической репликации

#репликация
Каждый мастер и координатор запускается с параметрами:

```
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
max_logical_replication_workers = 10
max_worker_processes = 20
```

Параметры передаются через аргументы командной строки `postgres -c param=value` прямо в манифесте StatefulSet — без монтирования `postgresql.conf`. Контейнер остаётся иммутабельным, конфиг живёт в `values.yaml`.


___
## Двусторонняя репликация между мастерами

Каждый мастер публикует свои изменения и подписывается на двух других — полная mesh-топология:

```sql
-- master-1 публикует
CREATE PUBLICATION master1_pub_app FOR TABLE app_users;

-- master-1 подписывается на master-2 и master-3
CREATE SUBSCRIPTION master1_sub_from_master2
  CONNECTION 'host=master-2.citus.svc.cluster.local ...'
  PUBLICATION master2_pub_app
  WITH (origin = none, copy_data = false);
```

Ключевой параметр — `origin = none`. Без него возникает бесконечный цикл: Master-1 пишет строку → реплицирует на Master-2 → Master-2 реплицирует обратно на Master-1 → и так до бесконечности. С `origin = none` PostgreSQL помечает транзакции источником и не пересылает чужие изменения обратно.

DNS-имена `master-2.citus.svc.cluster.local` резолвятся через `kube-dns` внутри namespace `citus` — независимость от IP-адресов.


___
## pg-locker — распределённый сервер блокировок

#pg-locker
Отдельный PostgreSQL-под с единственной ответственностью: сериализация конкурентных записей в multi-master системе.

### Таблица блокировок

```sql
CREATE TABLE locker.locks(
    table_name  text NOT NULL,
    key_text    text NOT NULL,
    coord_id    int  NOT NULL,
    created_at  timestamptz DEFAULT now(),
    PRIMARY KEY (table_name, key_text)
);
```

Первичный ключ `(table_name, key_text)` гарантирует: на одну строку конкретной таблицы — только один лок.

### Атомарный захват блокировки — try_lock

```sql
SELECT coord_id INTO v_coord_id
FROM locker.locks
WHERE table_name = p_table_name AND key_text = p_key_text
FOR UPDATE;
```

`SELECT ... FOR UPDATE` делает операцию атомарной на уровне движка СУБД. Логика:

1. Строки нет → INSERT, лок захвачен
2. Строка есть, `coord_id` совпадает → этот координатор уже держит лок, повторный вызов безопасен
3. Строка есть, `coord_id` другой → `EXCEPTION` с `errcode = 'lock_not_available'`

### Освобождение блокировки — release_lock

```sql
DELETE FROM locker.locks
WHERE table_name = p_table_name
  AND key_text = p_key_text
  AND coord_id = p_coord_id;
```

Проверка на `coord_id` — координатор не может освободить чужой лок.


___
## Интеграция мастеров с pg-locker через dblink

#pg-locker
Каждый мастер использует расширение `dblink` для вызова функций локера — cross-database RPC прямо внутри транзакции:

```sql
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE OR REPLACE FUNCTION locker_call_try_lock(
    p_table_name text, p_key_text text
) RETURNS void LANGUAGE plpgsql AS $func$
DECLARE
    coord_id int := 1;
BEGIN
    PERFORM dblink_exec(
        'host=pg-locker.citus.svc.cluster.local port=5432 ...',
        FORMAT(
            $$do $d$ begin perform locker.try_lock(%L, %L, %s); end $d$;$$,
            p_table_name, p_key_text, coord_id
        )
    );
END;
$func$;
```

`FORMAT` с `%L` — защита от SQL-инъекций: `table_name` и `key_text` экранируются как строковые литералы. `pg-locker.citus.svc.cluster.local` — Kubernetes DNS, сервис резолвится по имени.


___
## Headless Service для Citus Workers

#statefulset
Воркеры используют Headless Service (`clusterIP: None`). Это критически важно для Citus: координатор подключается к каждому воркеру напрямую по имени пода.

Обычный ClusterIP Service возвращает VIP-адрес — балансировщик. Citus не может гарантировать подключение к нужному поду через балансировщик. Headless Service заставляет `kube-dns` возвращать A-записи для каждого пода отдельно:

```
worker-1-0.worker-1-headless.citus.svc.cluster.local
worker-1-1.worker-1-headless.citus.svc.cluster.local
worker-1-2.worker-1-headless.citus.svc.cluster.local
```


___
## PVC и хранилище

Каждый StatefulSet имеет `volumeClaimTemplates` с `ReadWriteOnce` — один под монтирует диск, без конкурентных записей на уровне файловой системы:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: {{ .storageClassName }}
      resources:
        requests:
          storage: {{ .storageSize }}
```

Каждый узел получает уникальный `storageClassName` — полный контроль над физическим размещением данных.

Итоговый объём хранилища кластера: 3 мастера × 10Gi + 3 координатора × 10Gi + 9 воркеров × 10Gi + 1 локер × 5Gi = **155Gi**.


___
## Helm Chart — структура и параметризация

#helm
```
citus-chart/
  Chart.yaml
  values.yaml
  templates/
    namespace.yaml
    storageclass.yaml
    masters.yaml
    coordinators.yaml
    workers.yaml
    locker.yaml
```

Шаблонизация через `range` — один шаблон генерирует Service + StatefulSet для каждого элемента списка:

```yaml
{{- range .Values.masters }}
---
apiVersion: v1
kind: Service
...
{{- end }}
```

Добавить четвёртый мастер = одна строка в `values.yaml`, ни один шаблон не трогается.

Внутри `range` используется `$.Values` (глобальный контекст) для общих параметров и `.name`, `.replicas` (локальный контекст) для параметров конкретного узла.

Условный рендеринг локера: `{{- if .Values.locker.enabled }}` — отключается флагом без удаления файла.


___
## Namespace-изоляция

Весь кластер живёт в namespace `citus`:

1. Сетевая изоляция от других сервисов в том же Kubernetes
2. Простая очистка: `kubectl delete namespace citus` удаляет всё
3. DNS-суффикс `.citus.svc.cluster.local` для всех внутренних подключений


___
## Демо-схема — таблица app_users

Тестовая таблица для проверки репликации и шардирования:

```sql
CREATE TABLE app_users(
    id      uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    name    varchar,
    balance numeric
);
```

`gen_random_uuid()` как PK — правильный выбор для распределённой системы. `SERIAL` давал бы коллизии между мастерами, `uuid` — нет.


___
## Масштаб развёртывания

Один `helm install` создаёт:

- 1 Namespace
- ~13 StorageClass
- 13 Service (master-1..3, coordinator-1..3, worker-1..3-headless, pg-locker)
- 8 StatefulSet (master-1..3, coordinator-1..3, pg-locker)
- 3 StatefulSet с `replicas=3` для workers = 9 воркер-подов
- Итого подов: **16**

SQL-объекты скриптов инициализации: 3 publication, 6 subscription, 3 роли `repl_user`, 6 функций-обёрток над dblink, 1 схема `locker`, 1 таблица `locker.locks`, 2 функции на pg-locker.


___
## Проблемы, которые проект предотвращает

### Циклическая репликация
Без `origin = none`: Master-A пишет → реплицирует на B → B реплицирует обратно на A → бесконечный цикл. Решено параметром `origin = none` в `CREATE SUBSCRIPTION`.

### Split-brain при конкурентных записях
Без pg-locker: два клиента одновременно обновляют одну строку на двух разных мастерах — оба сделают UPDATE локально, оба отправят изменение по репликации — данные рассинхронизируются. pg-locker предотвращает это: первый захватывает лок, второй получает `lock_not_available` и откатывается.

### Потеря идентичности пода при рестарте
StatefulSet гарантирует: после перезапуска под получает то же имя и тот же PVC. PostgreSQL находит свои данные, продолжает работу с существующими слотами репликации — переинициализация не нужна.

### SQL-инъекция в динамическом SQL
`FORMAT` с `%L` экранирует строки как литералы — стандартная защита в PL/pgSQL.


___
## Применённые паттерны

- _**Infrastructure as Code**_ — весь кластер описан декларативно в YAML и SQL, воспроизводим на любом кластере
- _**GitOps**_ — репозиторий содержит всё необходимое для полного воспроизведения инфраструктуры
- _**Single Responsibility**_ — каждый компонент делает ровно одно: Masters → данные + HA, Coordinators → шардирование, Workers → хранение шардов, pg-locker → сериализация записей
- _**Centralized Lock Management**_ — паттерн внешнего Lock Server (аналог Redis SETNX, ZooKeeper ephemeral nodes), реализованный на чистом PostgreSQL
- _**Helm range + context separation**_ — `$.Values` для глобальных параметров, `.` для итерационных
