create schema if not exists locker;

create table locker.locks(
	table_name text not null,
	key_text text not null,
	coord_id int not null,
	created_at timestamptz default now(),
	primary key (table_name, key_text)
)


-- try_lock
create or replace function locker.try_lock(
	p_table_name text,
	p_key_text text,
	p_coord_id int
)
returns void
language plpgsql
as $func$
declare
	v_coord_id int;
begin
	select coord_id
	into v_coord_id
	from locker.locks
	where table_name = p_table_name and key_text = p_key_text
	for update;
	
	if not found then
		insert into locker.locks(table_name, key_text, coord_id)
		values (p_table_name, p_key_text, p_coord_id);
		return;
	end if;

	if v_coord_id = p_coord_id then return;
	end if;

	raise exception 'lock conflict for table=%, key=%, held by coord_id=%',
		p_table_name, p_key_text, v_coord_id
		using errcode = 'lock_not_available';
end;
$func$;


-- release_lock
create or replace function locker.release_lock(
	p_table_name text,
	p_key_text text,
	p_coord_id int
)
returns void
language plpgsql
as $func$
begin
	delete from locker.locks
	where table_name = p_table_name	and key_text = p_key_text and coord_id = p_coord_id;
	return;
end;
$func$
