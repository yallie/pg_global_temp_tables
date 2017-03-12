-- 1. Define a function returning the contents of a temporary table
-- 2. Define a view on the function
-- 3. Define instead of triggers on the view

-- Table structure is like this:
-- create temporary table if not exists temp_tag_idlist(tag bigint, id bigint) on commit drop;

-- Use a separate schema for the experiments
create schema if not exists stage;

create or replace function stage.temp_tag_idlist() returns table(tag bigint, id bigint) as $$
begin
	-- temporary table definition
	create temporary table if not exists temp_tag_idlist_table
	(
		tag bigint,
		id bigint,
		primary key(tag, id)
	)
	on commit drop;
	
	return query select * from temp_tag_idlist_table;
end;
$$ language plpgsql set client_min_messages to error;

create or replace view stage.temp_tag_idlist as 
	select * from stage.temp_tag_idlist();

create or replace function stage.temp_tag_idlist_iud() returns trigger as $$
begin
	-- temporary table definition
	create temporary table if not exists temp_tag_idlist_table
	(
		tag bigint,
		id bigint,
		primary key(tag, id)
	)
	on commit drop;

	-- to generate the following code, we need a list of columns formatted as follows:
	-- 1. id, tag (all columns)
	-- 2. new.id, new.tag (all columns)
	-- 3. id = new.id, tag = new.tag (all columns)
	-- 4. id = old.id, tag = old.tag (primary key columns only)
	if tg_op = 'INSERT' then
		insert into temp_tag_idlist_table(id, tag) 
		values (new.id, new.tag);
		return new;
	elsif tg_op = 'UPDATE' then
		update temp_tag_idlist_table 
		set id = new.id, tag = new.tag
		where id = old.id and tag = old.tag;
		return new;
	elsif tg_op = 'DELETE' then
		delete from temp_tag_idlist_table 
		where id = old.id and tag = old.tag;
		return old;
	end if;
end;
$$ language plpgsql set client_min_messages to error;

drop trigger if exists temp_tag_idlist_iud on stage.temp_tag_idlist;
create trigger temp_tag_idlist_iud 
	instead of insert or update or delete on stage.temp_tag_idlist
	for each row
	execute procedure stage.temp_tag_idlist_iud();

explain insert into stage.temp_tag_idlist(id, tag)
values (1,2), (2, 2);

explain select * from stage.temp_tag_idlist;

select * from stage.temp_tag_idlist;

insert into stage.temp_tag_idlist(id, tag)
values (1,2), (2, 2);

select * from stage.temp_tag_idlist;

-- Cleaning up:
-- drop function if exists stage.temp_tag_idlist() cascade;
-- drop function if exists stage.temp_tag_idlist_insert();
