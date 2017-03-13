-- pg_global_temp_tables_tests -- tests for pg_global_temp_tables
-- uses PGUnit: https://github.com/adrianandrei-ca/pgunit
--
-- PGUnit framework should be installed in the 'pgunit' schema:
-- select * from pgunit.test_run_suite('pg_global_temp_tables')
--
-- Emulates Oracle-style global temporary tables in PostgreSQL
-- Written by Alexey Yakovlev <yallie@yandex.ru>

create or replace function test_case_pg_global_temp_tables_create_fails_on_nonexistent() returns void as $$
begin
	-- use begin..exception block to simulate the inner transaction
	begin
		perform create_permanent_temp_table('pg_global_temp_tables_nonexistent_table');

		-- roll back all changes, including the created database objects
		raise exception 'Failed' using errcode = 'UTEST';
	exception
		when sqlstate 'UTMP1' then
			raise notice 'OK, transaction rolled back';
	end;
end;
$$ language plpgsql
set search_path from current;

create or replace function test_case_pg_global_temp_tables_create_succeeds() returns void as $$
declare
	v_count int;
begin
	-- use begin..exception block to simulate the inner transaction
	begin
		create temporary table if not exists pg_global_temp_tables_test_table
		(
			id bigint primary key,
			name varchar,
			dt timestamptz(0),
			count integer
		);

		insert into
			pg_global_temp_tables_test_table(id, name, dt, count)
		values
			(1, 'create_permanent_temp_table', now(), 123),
			(2, 'drop_permanent_temp_table', clock_timestamp(), 321);

		perform create_permanent_temp_table('pg_global_temp_tables_test_table');

		-- check that the data still exists
		select count(*) 
		into v_count
		from pg_global_temp_tables_test_table;

		perform pgunit.test_assertTrue('row count should be 2', v_count = 2);

		-- insert more data
		insert into
			pg_global_temp_tables_test_table(id, name, dt, count)
		values
			(3, 'test_case_pg_global_temp_tables_create', clock_timestamp(), 111);

		select count(*) 
		into v_count
		from pg_global_temp_tables_test_table;

		perform pgunit.test_assertTrue('row count should be 3', v_count = 3);

		-- update a few rows
		update pg_global_temp_tables_test_table 
		set count = 10 
		where id = 2;

		select count(*) 
		into v_count
		from pg_global_temp_tables_test_table
		where count = 10;

		perform pgunit.test_assertTrue('row count should be 1', v_count = 1);

		-- delete a row
		delete from pg_global_temp_tables_test_table where id = 1;

		select count(*) 
		into v_count
		from pg_global_temp_tables_test_table;

		perform pgunit.test_assertTrue('row count should be 2 again', v_count = 2);

		-- roll back all changes, including the created database objects
		raise exception 'OK' using errcode = 'UTEST';
	exception
		when sqlstate 'UTEST' then
			raise notice 'OK, transaction rolled back';
	end;
end;
$$ language plpgsql
set search_path from current;

create or replace function test_case_pg_global_temp_tables_drop_fails_on_nonexistent_table() returns void as $$
begin
	-- use begin..exception block to simulate the inner transaction
	begin
		perform drop_permanent_temp_table('pg_global_temp_tables_nonexistent_table');

		-- roll back all changes, including the created database objects
		raise exception 'Failed' using errcode = 'UTEST';
	exception
		when sqlstate 'UTMP2' then
			raise notice 'OK, transaction rolled back';
	end;
end;
$$ language plpgsql
set search_path from current;

create or replace function test_case_pg_global_temp_tables_drop_succeeds() returns void as $$
begin
	-- use begin..exception block to simulate the inner transaction
	begin
		create temporary table if not exists pg_global_temp_tables_test_table
		(
			id bigint primary key,
			name varchar,
			dt timestamptz(0),
			count integer
		);

		perform create_permanent_temp_table('pg_global_temp_tables_test_table');
		perform drop_permanent_temp_table('pg_global_temp_tables_test_table');

		-- roll back all changes, including the created database objects
		raise exception 'OK' using errcode = 'UTEST';
	exception
		when sqlstate 'UTEST' then
			raise notice 'OK, transaction rolled back';
	end;
end;
$$ language plpgsql
set search_path from current;
