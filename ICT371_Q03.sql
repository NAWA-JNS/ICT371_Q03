-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE books (
    book_id SERIAL       PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL        PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed   CHECK (due_on >= borrowed_on),
    CONSTRAINT ck_return_after_borrow  CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL    PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE          PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

-- ==== (b) Function fn_loan_fine: K2 per day after the due date, minimum 0
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- A returned loan stops accumulating fines: use the earlier of the two dates.
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);      -- date - date = whole days
END;
$$;

-- ==== (c) Procedure pr_return_loan
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date % (loan % was borrowed on %)', p_returned_on, p_loan_id, v_borrowed;
    END IF;

    -- returned_on is still NULL here, so the function measures the fine up to p_returned_on.
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans                                   -- return date and final fine stored together
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ==== (d) Trigger: AFTER UPDATE row trigger logging returned_on changes
CREATE OR REPLACE FUNCTION trg_fn_loans_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- IS DISTINCT FROM is NULL-safe
EXECUTE FUNCTION trg_fn_loans_audit();

-- ==== (e) View v_overdue_loans
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- ==== (f) Index: a given book's unreturned loans
-- Partial index: only unreturned rows are stored, so it stays small as returned loans pile up.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

-- ==== (g) Scheduled job: pr_refresh_overdue
-- "Unreturned as of p_as_of" = borrowed on/before that date and not yet returned by then.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE            -- same snapshot_date is replaced on rerun
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_overdue_daily',
    '10 0 * * *',                                 -- every day at 00:10
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$
);

-- ==== (a) Seed data: 3 books, 6 loans (dates relative to today so the demo always works)
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Operating System Concepts'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mary Tembo',    CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 1 open, overdue 6 days
    (1, 'John Zulu',     CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 open, not yet due
    (2, 'Grace Mumba',   CURRENT_DATE - 15, CURRENT_DATE - 1),   -- 3 will be returned on time
    (2, 'Peter Chanda',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 4 will be returned late
    (3, 'Ruth Lungu',    CURRENT_DATE - 14, CURRENT_DATE),       -- 5 open, due today (no fine)
    (1, 'Samuel Kunda',  CURRENT_DATE - 16, CURRENT_DATE - 2);   -- 6 open, overdue 2 days

CALL pr_return_loan(3, CURRENT_DATE - 3);     -- on time  -> fine 0
CALL pr_return_loan(4, CURRENT_DATE - 10);    -- 6 days late -> fine 12

SELECT * FROM books ORDER BY book_id;
SELECT * FROM loans ORDER BY loan_id;

-- ==== (b) Function tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
-- loan 4 stays at 12 even when asked for a date far in the future (returned loan stops accruing)
SELECT fn_loan_fine(4, CURRENT_DATE + 100) AS fine_loan4_in_100_days;
SELECT fn_loan_fine(1, CURRENT_DATE + 4)   AS fine_loan1_in_4_days;     -- (6+4) * 2 = 20
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3,  CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- already returned
DO $$ BEGIN CALL pr_return_loan(2,  CURRENT_DATE - 30); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- before borrowed_on
SELECT loan_id, returned_on, fine_amount FROM loans WHERE loan_id IN (2,3,4) ORDER BY loan_id;

-- ==== (d) Trigger tests
SELECT * FROM loan_audit ORDER BY audit_id;           -- rows for the two returns above
UPDATE loans SET borrower_name = 'Peter C. Chanda' WHERE loan_id = 4;   -- returned_on unchanged
UPDATE loans SET returned_on = returned_on WHERE loan_id = 4;           -- same date
SELECT COUNT(*) AS audit_rows_still_2 FROM loan_audit;

-- ==== (e) View
SELECT loan_id, title, borrower_name, due_on, fine_today FROM v_overdue_loans ORDER BY loan_id;
-- (loan 5 is due today, so it is not overdue; loan 2 is not yet due)

-- ==== (f) EXPLAIN for a book's unreturned loans
ANALYZE loans;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ==== (g) Run the job, rerun it: one row per snapshot_date
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;
CALL pr_refresh_overdue(CURRENT_DATE);                -- rerun: replaced, not duplicated
SELECT * FROM overdue_summary ORDER BY snapshot_date;
CALL pr_refresh_overdue(CURRENT_DATE - 12);           -- historical snapshot (loan 4 was still out then)
SELECT * FROM overdue_summary ORDER BY snapshot_date;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_overdue_daily';
