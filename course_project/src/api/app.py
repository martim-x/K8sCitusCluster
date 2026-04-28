from datetime import date
from decimal import Decimal
from uuid import UUID

import asyncpg
from fastapi import FastAPI, Request, Response

app = FastAPI()

DB_HOST = "localhost"
DB_NAME = "postgres"

CONNECTIONS = {
    "guest": {
        "user": "guest_user",
        "password": "guest_123",
    },
    "user": {
        "user": "app_user",
        "password": "user_123",
    },
    "manager": {
        "user": "manager_user",
        "password": "manager_123",
    },
    "admin": {
        "user": "admin_user",
        "password": "admin_123",
    },
}

ALLOWED_PORTS = {5432, 5433, 5434}
DEFAULT_CONN_TYPE = "guest"
DEFAULT_DB_PORT = 5432


def get_conn_type(request: Request) -> str:
    conn_type = request.cookies.get("conn_type", DEFAULT_CONN_TYPE)
    if conn_type not in CONNECTIONS:
        return DEFAULT_CONN_TYPE
    return conn_type


def get_db_port(request: Request) -> int:
    raw = request.cookies.get("db_port", str(DEFAULT_DB_PORT))
    try:
        port = int(raw)
    except Exception:
        return DEFAULT_DB_PORT

    if port not in ALLOWED_PORTS:
        return DEFAULT_DB_PORT

    return port


def set_connection_cookies(response: Response, conn_type: str, db_port: int):
    if conn_type not in CONNECTIONS:
        conn_type = DEFAULT_CONN_TYPE

    if db_port not in ALLOWED_PORTS:
        db_port = DEFAULT_DB_PORT

    response.set_cookie(
        key="conn_type",
        value=conn_type,
        httponly=True,
        samesite="lax",
    )

    response.set_cookie(
        key="db_port",
        value=str(db_port),
        httponly=True,
        samesite="lax",
    )


async def get_conn(request: Request):
    conn_type = get_conn_type(request)
    db_port = get_db_port(request)
    cfg = CONNECTIONS[conn_type]

    return await asyncpg.connect(
        host=DB_HOST,
        port=db_port,
        database=DB_NAME,
        user=cfg["user"],
        password=cfg["password"],
    )


def row_to_dict(row):
    if row is None:
        return None
    return dict(row)


async def fetch_all(request: Request, sql: str, *args):
    conn = await get_conn(request)
    try:
        rows = await conn.fetch(sql, *args)
        return [row_to_dict(r) for r in rows]
    finally:
        await conn.close()


async def fetch_one(request: Request, sql: str, *args):
    conn = await get_conn(request)
    try:
        row = await conn.fetchrow(sql, *args)
        return row_to_dict(row)
    finally:
        await conn.close()


async def fetch_val(request: Request, sql: str, *args):
    conn = await get_conn(request)
    try:
        value = await conn.fetchval(sql, *args)
        return {"result": value}
    finally:
        await conn.close()


# ============================================================
# auth / connection
# ============================================================


@app.post("/connect/{conn_type}/{db_port}", tags=["auth"])
async def connect(conn_type: str, db_port: int, response: Response):
    set_connection_cookies(response, conn_type, db_port)
    return {
        "ok": True,
        "conn_type": conn_type if conn_type in CONNECTIONS else DEFAULT_CONN_TYPE,
        "db_port": db_port if db_port in ALLOWED_PORTS else DEFAULT_DB_PORT,
    }


@app.post("/login/{conn_type}", tags=["auth"])
async def login(conn_type: str, response: Response):
    current_port = DEFAULT_DB_PORT
    set_connection_cookies(response, conn_type, current_port)
    return {
        "ok": True,
        "conn_type": conn_type if conn_type in CONNECTIONS else DEFAULT_CONN_TYPE,
        "db_port": current_port,
    }


@app.post("/set-port/{db_port}", tags=["auth"])
async def set_port(request: Request, db_port: int, response: Response):
    current_conn_type = get_conn_type(request)
    set_connection_cookies(response, current_conn_type, db_port)
    return {
        "ok": True,
        "conn_type": current_conn_type,
        "db_port": db_port if db_port in ALLOWED_PORTS else DEFAULT_DB_PORT,
    }


@app.post("/logout", tags=["auth"])
async def logout(response: Response):
    response.delete_cookie("conn_type")
    response.delete_cookie("db_port")
    return {"ok": True}


@app.get("/me", tags=["auth"])
async def me(request: Request):
    return {
        "conn_type": get_conn_type(request),
        "db_port": get_db_port(request),
    }


# ============================================================
# util
# ============================================================


@app.get("/util/sanitize_text", tags=["util"])
async def sanitize_text(request: Request, p_value: str, p_field_name: str = "field"):
    return await fetch_val(
        request, "select util.sanitize_text($1, $2)", p_value, p_field_name
    )


@app.get("/util/is_record_active", tags=["util"])
async def is_record_active(request: Request, p_table_name: str, p_id: UUID):
    return await fetch_val(
        request, "select util.is_record_active($1, $2)", p_table_name, p_id
    )


@app.get("/util/validate_exists_by_id", tags=["util"])
async def validate_exists_by_id(request: Request, p_table_name: str, p_id: UUID):
    conn = await get_conn(request)
    try:
        await conn.execute(
            "select util.validate_exists_by_id($1, $2)", p_table_name, p_id
        )
        return {"ok": True}
    finally:
        await conn.close()


@app.post("/util/set_entity_lifecycle", tags=["util"])
async def set_entity_lifecycle(
    request: Request, p_table_name: str, p_id: UUID, p_is_deleted: bool
):
    return await fetch_val(
        request,
        "select util.set_entity_lifecycle($1, $2, $3)",
        p_table_name,
        p_id,
        p_is_deleted,
    )


# ============================================================
# app.roles
# ============================================================


@app.get("/app/get_app_roles", tags=["app.roles"])
async def get_app_roles(request: Request):
    return await fetch_all(request, "select * from app.get_app_roles()")


@app.get("/app/get_app_role_by_uuid", tags=["app.roles"])
async def get_app_role_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(request, "select * from app.get_app_role_by_uuid($1)", p_id)


@app.post("/app/create_app_role", tags=["app.roles"])
async def create_app_role(request: Request, p_name: str):
    return await fetch_val(request, "select app.create_app_role($1)", p_name)


@app.put("/app/update_app_role_by_uuid", tags=["app.roles"])
async def update_app_role_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select app.update_app_role_by_uuid($1, $2)", p_id, p_name
    )


@app.delete("/app/delete_app_role_by_uuid", tags=["app.roles"])
async def delete_app_role_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select app.delete_app_role_by_uuid($1)", p_id)


@app.patch("/app/restore_app_role_by_uuid", tags=["app.roles"])
async def restore_app_role_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select app.restore_app_role_by_uuid($1)", p_id)


# ============================================================
# app.users
# ============================================================


@app.get("/app/get_app_users", tags=["app.users"])
async def get_app_users(request: Request):
    return await fetch_all(request, "select * from app.get_app_users()")


@app.get("/app/get_app_user_by_uuid", tags=["app.users"])
async def get_app_user_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(request, "select * from app.get_app_user_by_uuid($1)", p_id)


@app.get("/app/get_own_app_user", tags=["app.users"])
async def get_own_app_user(request: Request, p_current_user_id: UUID):
    return await fetch_one(
        request,
        "select * from app.get_own_app_user($1)",
        p_current_user_id,
    )


@app.post("/app/create_app_user", tags=["app.users"])
async def create_app_user(
    request: Request, p_email: str, p_password: str, p_app_user_profile_id: UUID
):
    return await fetch_val(
        request,
        "select app.create_app_user($1, $2, $3)",
        p_email,
        p_password,
        p_app_user_profile_id,
    )


@app.put("/app/update_app_user_by_uuid", tags=["app.users"])
async def update_app_user_by_uuid(
    request: Request,
    p_id: UUID,
    p_email: str,
    p_password: str,
    p_app_user_profile_id: UUID,
):
    return await fetch_val(
        request,
        "select app.update_app_user_by_uuid($1, $2, $3, $4)",
        p_id,
        p_email,
        p_password,
        p_app_user_profile_id,
    )


@app.delete("/app/delete_app_user_by_uuid", tags=["app.users"])
async def delete_app_user_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select app.delete_app_user_by_uuid($1)", p_id)


@app.patch("/app/restore_app_user_by_uuid", tags=["app.users"])
async def restore_app_user_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select app.restore_app_user_by_uuid($1)", p_id)


# ============================================================
# profile.user_profiles
# ============================================================


@app.get("/profile/get_app_user_profiles", tags=["profile.user_profiles"])
async def get_app_user_profiles(request: Request):
    return await fetch_all(request, "select * from profile.get_app_user_profiles()")


@app.get("/profile/get_app_user_profile_by_uuid", tags=["profile.user_profiles"])
async def get_app_user_profile_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from profile.get_app_user_profile_by_uuid($1)", p_id
    )


@app.get("/profile/get_own_app_user_profile", tags=["profile.user_profiles"])
async def get_own_app_user_profile(request: Request, p_current_user_id: UUID):
    return await fetch_one(
        request,
        "select * from profile.get_own_app_user_profile($1)",
        p_current_user_id,
    )


@app.post("/profile/create_app_user_profile", tags=["profile.user_profiles"])
async def create_app_user_profile(request: Request, p_name: str, p_app_role_id: UUID):
    return await fetch_val(
        request, "select profile.create_app_user_profile($1, $2)", p_name, p_app_role_id
    )


@app.put("/profile/update_app_user_profile_by_uuid", tags=["profile.user_profiles"])
async def update_app_user_profile_by_uuid(
    request: Request, p_id: UUID, p_name: str, p_app_role_id: UUID
):
    return await fetch_val(
        request,
        "select profile.update_app_user_profile_by_uuid($1, $2, $3)",
        p_id,
        p_name,
        p_app_role_id,
    )


@app.delete("/profile/delete_app_user_profile_by_uuid", tags=["profile.user_profiles"])
async def delete_app_user_profile_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select profile.delete_app_user_profile_by_uuid($1)", p_id
    )


@app.patch("/profile/restore_app_user_profile_by_uuid", tags=["profile.user_profiles"])
async def restore_app_user_profile_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select profile.restore_app_user_profile_by_uuid($1)", p_id
    )


# ============================================================
# content.brands
# ============================================================


@app.get("/content/get_brands", tags=["content.brands"])
async def get_brands(request: Request):
    return await fetch_all(request, "select * from content.get_brands()")


@app.get("/content/get_brand_by_uuid", tags=["content.brands"])
async def get_brand_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(request, "select * from content.get_brand_by_uuid($1)", p_id)


@app.post("/content/create_brand", tags=["content.brands"])
async def create_brand(request: Request, p_name: str):
    return await fetch_val(request, "select content.create_brand($1)", p_name)


@app.put("/content/update_brand_by_uuid", tags=["content.brands"])
async def update_brand_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select content.update_brand_by_uuid($1, $2)", p_id, p_name
    )


@app.delete("/content/delete_brand_by_uuid", tags=["content.brands"])
async def delete_brand_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.delete_brand_by_uuid($1)", p_id)


@app.patch("/content/restore_brand_by_uuid", tags=["content.brands"])
async def restore_brand_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.restore_brand_by_uuid($1)", p_id)


# ============================================================
# content.drive_types
# ============================================================


@app.get("/content/get_drive_types", tags=["content.drive_types"])
async def get_drive_types(request: Request):
    return await fetch_all(request, "select * from content.get_drive_types()")


@app.get("/content/get_drive_type_by_uuid", tags=["content.drive_types"])
async def get_drive_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from content.get_drive_type_by_uuid($1)", p_id
    )


@app.post("/content/create_drive_type", tags=["content.drive_types"])
async def create_drive_type(request: Request, p_name: str):
    return await fetch_val(request, "select content.create_drive_type($1)", p_name)


@app.put("/content/update_drive_type_by_uuid", tags=["content.drive_types"])
async def update_drive_type_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select content.update_drive_type_by_uuid($1, $2)", p_id, p_name
    )


@app.delete("/content/delete_drive_type_by_uuid", tags=["content.drive_types"])
async def delete_drive_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.delete_drive_type_by_uuid($1)", p_id
    )


@app.patch("/content/restore_drive_type_by_uuid", tags=["content.drive_types"])
async def restore_drive_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.restore_drive_type_by_uuid($1)", p_id
    )


# ============================================================
# content.transmission_types
# ============================================================


@app.get("/content/get_transmission_types", tags=["content.transmission_types"])
async def get_transmission_types(request: Request):
    return await fetch_all(request, "select * from content.get_transmission_types()")


@app.get("/content/get_transmission_type_by_uuid", tags=["content.transmission_types"])
async def get_transmission_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from content.get_transmission_type_by_uuid($1)", p_id
    )


@app.post("/content/create_transmission_type", tags=["content.transmission_types"])
async def create_transmission_type(request: Request, p_name: str):
    return await fetch_val(
        request, "select content.create_transmission_type($1)", p_name
    )


@app.put(
    "/content/update_transmission_type_by_uuid", tags=["content.transmission_types"]
)
async def update_transmission_type_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select content.update_transmission_type_by_uuid($1, $2)", p_id, p_name
    )


@app.delete(
    "/content/delete_transmission_type_by_uuid", tags=["content.transmission_types"]
)
async def delete_transmission_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.delete_transmission_type_by_uuid($1)", p_id
    )


@app.patch(
    "/content/restore_transmission_type_by_uuid", tags=["content.transmission_types"]
)
async def restore_transmission_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.restore_transmission_type_by_uuid($1)", p_id
    )


# ============================================================
# content.usage_types
# ============================================================


@app.get("/content/get_usage_types", tags=["content.usage_types"])
async def get_usage_types(request: Request):
    return await fetch_all(request, "select * from content.get_usage_types()")


@app.get("/content/get_usage_type_by_uuid", tags=["content.usage_types"])
async def get_usage_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from content.get_usage_type_by_uuid($1)", p_id
    )


@app.post("/content/create_usage_type", tags=["content.usage_types"])
async def create_usage_type(request: Request, p_name: str):
    return await fetch_val(request, "select content.create_usage_type($1)", p_name)


@app.put("/content/update_usage_type_by_uuid", tags=["content.usage_types"])
async def update_usage_type_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select content.update_usage_type_by_uuid($1, $2)", p_id, p_name
    )


@app.delete("/content/delete_usage_type_by_uuid", tags=["content.usage_types"])
async def delete_usage_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.delete_usage_type_by_uuid($1)", p_id
    )


@app.patch("/content/restore_usage_type_by_uuid", tags=["content.usage_types"])
async def restore_usage_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.restore_usage_type_by_uuid($1)", p_id
    )


# ============================================================
# content.capacity_types
# ============================================================


@app.get("/content/get_capacity_types", tags=["content.capacity_types"])
async def get_capacity_types(request: Request):
    return await fetch_all(request, "select * from content.get_capacity_types()")


@app.get("/content/get_capacity_type_by_uuid", tags=["content.capacity_types"])
async def get_capacity_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from content.get_capacity_type_by_uuid($1)", p_id
    )


@app.post("/content/create_capacity_type", tags=["content.capacity_types"])
async def create_capacity_type(request: Request, p_name: str):
    return await fetch_val(request, "select content.create_capacity_type($1)", p_name)


@app.put("/content/update_capacity_type_by_uuid", tags=["content.capacity_types"])
async def update_capacity_type_by_uuid(request: Request, p_id: UUID, p_name: str):
    return await fetch_val(
        request, "select content.update_capacity_type_by_uuid($1, $2)", p_id, p_name
    )


@app.delete("/content/delete_capacity_type_by_uuid", tags=["content.capacity_types"])
async def delete_capacity_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.delete_capacity_type_by_uuid($1)", p_id
    )


@app.patch("/content/restore_capacity_type_by_uuid", tags=["content.capacity_types"])
async def restore_capacity_type_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request, "select content.restore_capacity_type_by_uuid($1)", p_id
    )


# ============================================================
# content.capacities
# ============================================================


@app.get("/content/get_capacities", tags=["content.capacities"])
async def get_capacities(request: Request):
    return await fetch_all(request, "select * from content.get_capacities()")


@app.get("/content/get_capacity_by_uuid", tags=["content.capacities"])
async def get_capacity_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request, "select * from content.get_capacity_by_uuid($1)", p_id
    )


@app.post("/content/create_capacity", tags=["content.capacities"])
async def create_capacity(request: Request, p_value: int, p_capacity_type_id: UUID):
    return await fetch_val(
        request, "select content.create_capacity($1, $2)", p_value, p_capacity_type_id
    )


@app.put("/content/update_capacity_by_uuid", tags=["content.capacities"])
async def update_capacity_by_uuid(
    request: Request, p_id: UUID, p_value: int, p_capacity_type_id: UUID
):
    return await fetch_val(
        request,
        "select content.update_capacity_by_uuid($1, $2, $3)",
        p_id,
        p_value,
        p_capacity_type_id,
    )


@app.delete("/content/delete_capacity_by_uuid", tags=["content.capacities"])
async def delete_capacity_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.delete_capacity_by_uuid($1)", p_id)


@app.patch("/content/restore_capacity_by_uuid", tags=["content.capacities"])
async def restore_capacity_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.restore_capacity_by_uuid($1)", p_id)


# ============================================================
# content.cars
# ============================================================


@app.get("/content/get_cars", tags=["content.cars"])
async def get_cars(request: Request):
    return await fetch_all(request, "select * from content.get_cars()")


@app.get("/content/get_car_by_uuid", tags=["content.cars"])
async def get_car_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(request, "select * from content.get_car_by_uuid($1)", p_id)


@app.post("/content/create_car", tags=["content.cars"])
async def create_car(
    request: Request,
    p_name: str,
    p_price_of_origin: Decimal,
    p_manufacture_date: date,
    p_country_of_origin: str,
    p_description: str,
    p_brand_id: UUID,
    p_drive_type_id: UUID,
    p_transmission_type_id: UUID,
    p_usage_type_id: UUID,
    p_capacity_id: UUID,
):
    return await fetch_val(
        request,
        "select content.create_car($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        p_name,
        p_price_of_origin,
        p_manufacture_date,
        p_country_of_origin,
        p_description,
        p_brand_id,
        p_drive_type_id,
        p_transmission_type_id,
        p_usage_type_id,
        p_capacity_id,
    )


@app.put("/content/update_car_by_uuid", tags=["content.cars"])
async def update_car_by_uuid(
    request: Request,
    p_id: UUID,
    p_name: str,
    p_price_of_origin: Decimal,
    p_manufacture_date: date,
    p_country_of_origin: str,
    p_description: str,
    p_brand_id: UUID,
    p_drive_type_id: UUID,
    p_transmission_type_id: UUID,
    p_usage_type_id: UUID,
    p_capacity_id: UUID,
):
    return await fetch_val(
        request,
        "select content.update_car_by_uuid($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
        p_id,
        p_name,
        p_price_of_origin,
        p_manufacture_date,
        p_country_of_origin,
        p_description,
        p_brand_id,
        p_drive_type_id,
        p_transmission_type_id,
        p_usage_type_id,
        p_capacity_id,
    )


@app.delete("/content/delete_car_by_uuid", tags=["content.cars"])
async def delete_car_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.delete_car_by_uuid($1)", p_id)


@app.patch("/content/restore_car_by_uuid", tags=["content.cars"])
async def restore_car_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(request, "select content.restore_car_by_uuid($1)", p_id)


# ============================================================
# content.requests
# ============================================================


@app.get("/content/get_app_requests", tags=["content.requests"])
async def get_app_requests(request: Request):
    return await fetch_all(
        request,
        "select * from content.get_app_requests()",
    )


@app.get("/content/get_app_request_by_uuid", tags=["content.requests"])
async def get_app_request_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request,
        "select * from content.get_app_request_by_uuid($1)",
        p_id,
    )


@app.get("/content/get_own_app_requests", tags=["content.requests"])
async def get_own_app_requests(request: Request, p_current_user_id: UUID):
    return await fetch_all(
        request,
        "select * from content.get_own_app_requests($1)",
        p_current_user_id,
    )


@app.get("/content/get_own_app_request_by_uuid", tags=["content.requests"])
async def get_own_app_request_by_uuid(
    request: Request,
    p_current_user_id: UUID,
    p_request_id: UUID,
):
    return await fetch_one(
        request,
        "select * from content.get_own_app_request_by_uuid($1, $2)",
        p_current_user_id,
        p_request_id,
    )


@app.post("/content/create_app_request", tags=["content.requests"])
async def create_app_request(
    request: Request,
    p_app_user_id: UUID,
    p_car_id: UUID,
    p_comment: str | None = None,
):
    return await fetch_val(
        request,
        "select content.create_app_request($1, $2, $3)",
        p_app_user_id,
        p_car_id,
        p_comment,
    )


@app.put("/content/update_app_request_by_uuid", tags=["content.requests"])
async def update_app_request_by_uuid(
    request: Request,
    p_id: UUID,
    p_app_user_id: UUID,
    p_car_id: UUID,
    p_comment: str | None = None,
):
    return await fetch_val(
        request,
        "select content.update_app_request_by_uuid($1, $2, $3, $4)",
        p_id,
        p_app_user_id,
        p_car_id,
        p_comment,
    )


@app.delete("/content/delete_app_request_by_uuid", tags=["content.requests"])
async def delete_app_request_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.delete_app_request_by_uuid($1)",
        p_id,
    )


@app.patch("/content/restore_app_request_by_uuid", tags=["content.requests"])
async def restore_app_request_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.restore_app_request_by_uuid($1)",
        p_id,
    )


# ============================================================
# content.orders
# ============================================================


@app.get("/content/get_app_orders", tags=["content.orders"])
async def get_app_orders(request: Request):
    return await fetch_all(
        request,
        "select * from content.get_app_orders()",
    )


@app.get("/content/get_app_order_by_uuid", tags=["content.orders"])
async def get_app_order_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request,
        "select * from content.get_app_order_by_uuid($1)",
        p_id,
    )


@app.get("/content/get_own_app_orders", tags=["content.orders"])
async def get_own_app_orders(request: Request, p_current_user_id: UUID):
    return await fetch_all(
        request,
        "select * from content.get_own_app_orders($1)",
        p_current_user_id,
    )


@app.get("/content/get_own_app_order_by_uuid", tags=["content.orders"])
async def get_own_app_order_by_uuid(
    request: Request,
    p_current_user_id: UUID,
    p_order_id: UUID,
):
    return await fetch_one(
        request,
        "select * from content.get_own_app_order_by_uuid($1, $2)",
        p_current_user_id,
        p_order_id,
    )


@app.post("/content/create_app_order", tags=["content.orders"])
async def create_app_order(
    request: Request,
    p_order_date: date,
    p_period_months: int,
    p_down_payment: Decimal,
    p_monthly_payment: Decimal,
    p_app_user_id: UUID,
    p_manager_id: UUID,
    p_app_request_id: UUID,
    p_comment: str | None = None,
):
    return await fetch_val(
        request,
        "select content.create_app_order($1, $2, $3, $4, $5, $6, $7, $8)",
        p_order_date,
        p_period_months,
        p_down_payment,
        p_monthly_payment,
        p_app_user_id,
        p_manager_id,
        p_app_request_id,
        p_comment,
    )


@app.put("/content/update_app_order_by_uuid", tags=["content.orders"])
async def update_app_order_by_uuid(
    request: Request,
    p_id: UUID,
    p_order_date: date,
    p_period_months: int,
    p_down_payment: Decimal,
    p_monthly_payment: Decimal,
    p_app_user_id: UUID,
    p_manager_id: UUID,
    p_app_request_id: UUID,
    p_comment: str | None = None,
):
    return await fetch_val(
        request,
        "select content.update_app_order_by_uuid($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        p_id,
        p_order_date,
        p_period_months,
        p_down_payment,
        p_monthly_payment,
        p_app_user_id,
        p_manager_id,
        p_app_request_id,
        p_comment,
    )


@app.delete("/content/delete_app_order_by_uuid", tags=["content.orders"])
async def delete_app_order_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.delete_app_order_by_uuid($1)",
        p_id,
    )


@app.patch("/content/restore_app_order_by_uuid", tags=["content.orders"])
async def restore_app_order_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.restore_app_order_by_uuid($1)",
        p_id,
    )


# ============================================================
# content.statuses
# ============================================================


@app.get("/content/get_app_statuses", tags=["content.statuses"])
async def get_app_statuses(request: Request):
    return await fetch_all(
        request,
        "select * from content.get_app_statuses()",
    )


@app.get("/content/get_app_status_by_uuid", tags=["content.statuses"])
async def get_app_status_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request,
        "select * from content.get_app_status_by_uuid($1)",
        p_id,
    )


@app.post("/content/create_app_status", tags=["content.statuses"])
async def create_app_status(request: Request, p_name: str):
    return await fetch_val(
        request,
        "select content.create_app_status($1)",
        p_name,
    )


@app.put("/content/update_app_status_by_uuid", tags=["content.statuses"])
async def update_app_status_by_uuid(
    request: Request,
    p_id: UUID,
    p_name: str,
):
    return await fetch_val(
        request,
        "select content.update_app_status_by_uuid($1, $2)",
        p_id,
        p_name,
    )


@app.delete("/content/delete_app_status_by_uuid", tags=["content.statuses"])
async def delete_app_status_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.delete_app_status_by_uuid($1)",
        p_id,
    )


@app.patch("/content/restore_app_status_by_uuid", tags=["content.statuses"])
async def restore_app_status_by_uuid(request: Request, p_id: UUID):
    return await fetch_val(
        request,
        "select content.restore_app_status_by_uuid($1)",
        p_id,
    )


# ============================================================
# content.request_status_histories
# ============================================================


@app.get(
    "/content/get_app_request_status_histories",
    tags=["content.request_status_histories"],
)
async def get_app_request_status_histories(request: Request):
    return await fetch_all(
        request,
        "select * from content.get_app_request_status_histories()",
    )


@app.get(
    "/content/get_app_request_status_history_by_uuid",
    tags=["content.request_status_histories"],
)
async def get_app_request_status_history_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request,
        "select * from content.get_app_request_status_history_by_uuid($1)",
        p_id,
    )


@app.get(
    "/content/get_own_app_request_status_histories",
    tags=["content.request_status_histories"],
)
async def get_own_app_request_status_histories(
    request: Request,
    p_current_user_id: UUID,
):
    return await fetch_all(
        request,
        "select * from content.get_own_app_request_status_histories($1)",
        p_current_user_id,
    )


@app.get(
    "/content/get_own_app_request_status_histories_by_request",
    tags=["content.request_status_histories"],
)
async def get_own_app_request_status_histories_by_request(
    request: Request,
    p_current_user_id: UUID,
    p_request_id: UUID,
):
    return await fetch_all(
        request,
        "select * from content.get_own_app_request_status_histories_by_request($1, $2)",
        p_current_user_id,
        p_request_id,
    )


@app.post(
    "/content/create_app_request_status_history",
    tags=["content.request_status_histories"],
)
async def create_app_request_status_history(
    request: Request,
    p_app_status_id: UUID,
    p_app_request_id: UUID,
):
    return await fetch_val(
        request,
        "select content.create_app_request_status_history($1, $2)",
        p_app_status_id,
        p_app_request_id,
    )


# ============================================================
# content.order_status_histories
# ============================================================


@app.get(
    "/content/get_app_order_status_histories",
    tags=["content.order_status_histories"],
)
async def get_app_order_status_histories(request: Request):
    return await fetch_all(
        request,
        "select * from content.get_app_order_status_histories()",
    )


@app.get(
    "/content/get_app_order_status_history_by_uuid",
    tags=["content.order_status_histories"],
)
async def get_app_order_status_history_by_uuid(request: Request, p_id: UUID):
    return await fetch_one(
        request,
        "select * from content.get_app_order_status_history_by_uuid($1)",
        p_id,
    )


@app.get(
    "/content/get_own_app_order_status_histories",
    tags=["content.order_status_histories"],
)
async def get_own_app_order_status_histories(
    request: Request,
    p_current_user_id: UUID,
):
    return await fetch_all(
        request,
        "select * from content.get_own_app_order_status_histories($1)",
        p_current_user_id,
    )


@app.get(
    "/content/get_own_app_order_status_histories_by_order",
    tags=["content.order_status_histories"],
)
async def get_own_app_order_status_histories_by_order(
    request: Request,
    p_current_user_id: UUID,
    p_order_id: UUID,
):
    return await fetch_all(
        request,
        "select * from content.get_own_app_order_status_histories_by_order($1, $2)",
        p_current_user_id,
        p_order_id,
    )


@app.post(
    "/content/create_app_order_status_history",
    tags=["content.order_status_histories"],
)
async def create_app_order_status_history(
    request: Request,
    p_app_status_id: UUID,
    p_app_order_id: UUID,
):
    return await fetch_val(
        request,
        "select content.create_app_order_status_history($1, $2)",
        p_app_status_id,
        p_app_order_id,
    )
