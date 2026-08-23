-- Added on its own, ahead of anything that uses it.
--
-- Postgres runs each migration in a transaction, and a newly added enum label
-- cannot be referenced by the same transaction that created it. Splitting this
-- out means the migration that seeds and filters on STUDENT runs against a
-- type that already has it.
ALTER TYPE "Role" ADD VALUE IF NOT EXISTS 'STUDENT';
