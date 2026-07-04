-- add_ticket_search (down)
DROP TRIGGER tickets_search_vector_trig ON tickets;
DROP FUNCTION tickets_search_vector_update();
DROP INDEX tickets_search_idx;
