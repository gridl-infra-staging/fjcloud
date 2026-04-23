-- One-time backfill: initialize last_accessed_at for all existing tenants.
-- Prevents immediate cold tiering on deploy by marking all current indexes
-- as "recently accessed". Run once after deploying Stage 8 migrations.

UPDATE customer_tenants
   SET last_accessed_at = NOW()
 WHERE last_accessed_at IS NULL;
