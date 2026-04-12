import os
from contextlib import asynccontextmanager

from asyncpg import Connection, Transaction, connect
from dotenv import load_dotenv

load_dotenv()

# =====================
# DB CONF
# =====================

DB_MASTER_CONF = {
    "user": os.getenv("DB_ADMIN"),
    "password": os.getenv("DB_ADMIN_PASS"),
    "host": os.getenv("DB_HOST"),
    "port": int(os.getenv("DB_PORT_FROM_MASTER")),
    "database": os.getenv("DB_NAME"),
}

DB_SLAVE_CONF = {
    "user": os.getenv("DB_ADMIN"),
    "password": os.getenv("DB_ADMIN_PASS"),
    "host": os.getenv("DB_HOST"),
    "port": int(os.getenv("DB_PORT_FROM_SLAVE")),
    "database": os.getenv("DB_NAME"),
}

TABLES = [
    "app_order_status_history",
    "app_request_status_history",
    "app_status",
    "profile_filter_brand",
    "profile_filter_drive_type",
    "profile_filter_transmission_type",
    "profile_filter_usage_type",
    "profile_filter_capacity",
    "car",
    "car_passport",
    "capacity",
    "capacity_type",
    "drive_type",
    "transmission_type",
    "usage_type",
    "brand",
    "app_user",
    "app_user_profile",
    "app_role",
]

# =====================
# DB CONNECTION
# =====================


def _db_conf(read_only: bool = False) -> dict:
    return DB_SLAVE_CONF if read_only else DB_MASTER_CONF


@asynccontextmanager
async def get_tx_connection(read_only=False, isolation: str = "serializable"):
    conn: Connection = await connect(**_db_conf(read_only))
    tx: Transaction = conn.transaction(isolation=isolation, readonly=read_only)
    await tx.start()
    try:
        yield conn
        await tx.commit()
    except Exception:
        await tx.rollback()
        raise
    finally:
        await conn.close()


@asynccontextmanager
async def get_connection(read_only: bool = False):
    conn: Connection = await connect(**_db_conf(read_only))
    try:
        yield conn
    finally:
        await conn.close()

        await conn.execute("SELECT pg_reload_conf()")


# =====================
# PREPARE DBS
# =====================


async def prepare_master():
    async with get_connection(read_only=False) as conn:
        await conn.execute("ALTER SYSTEM SET wal_level = 'logical'")
        await conn.execute("ALTER SYSTEM SET max_wal_senders = '10'")
        await conn.execute("ALTER SYSTEM SET max_replication_slots = '10'")
        await conn.execute("SELECT pg_reload_conf()")


async def setup_master_publication():
    async with get_tx_connection(read_only=False) as conn:
        await conn.execute(
            """
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_roles WHERE rolname = 'repl_user'
                ) THEN
                    CREATE ROLE repl_user
                        WITH LOGIN REPLICATION PASSWORD '111';
                END IF;
            END
            $$;
            """
        )

        await conn.execute("DROP PUBLICATION IF EXISTS app_pub")

        await conn.execute(
            f"""
            CREATE PUBLICATION app_pub
            FOR TABLE {",".join(TABLES)}
            WITH (publish = 'insert, update, delete')
            """
        )


async def setup_slave_subscription():
    db_image = os.getenv("DB_IMAGE")
    db_version = os.getenv("DB_VERSION")
    db_name = os.getenv("DB_NAME")
    db_port = os.getenv("DB_PORT_TO_MASTER", "5432")

    master_host = f"{db_image}-{db_version}-master"

    async with get_connection(read_only=True) as conn:
        await conn.execute("DROP SUBSCRIPTION IF EXISTS app_sub")

        await conn.execute(
            f"""
            CREATE SUBSCRIPTION app_sub
            CONNECTION 'host={master_host} port={db_port} dbname={db_name} user=repl_user password=111'
            PUBLICATION app_pub
            WITH (copy_data = false)
            """
        )
