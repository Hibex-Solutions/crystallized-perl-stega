-- 4 up
CREATE INDEX tickets_search_idx ON tickets USING GIN (search_vector);

CREATE OR REPLACE FUNCTION tickets_search_vector_update()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('portuguese', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('portuguese', coalesce(NEW.body,  '')), 'B');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tickets_search_vector_trig
BEFORE INSERT OR UPDATE OF title, body ON tickets
FOR EACH ROW EXECUTE FUNCTION tickets_search_vector_update();

-- 4 down
DROP TRIGGER tickets_search_vector_trig ON tickets;
DROP FUNCTION tickets_search_vector_update();
DROP INDEX tickets_search_idx;
