# Customer Suspension

## What triggers suspension

A customer is suspended when all payment retries are exhausted on a failed invoice. This happens automatically via the Stripe `payment_failed` webhook handler in `webhooks.rs`.

Flow: `payment_intent.payment_failed` webhook → `handle_payment_failed` → check retry count → if exhausted → `tenant_repo.suspend(customer_id)` → customer gets 403 on all tenant endpoints.

A Critical alert fires when this happens (via AlertService).

## Checking suspension status

1. **Admin panel**: `/admin/customers` — look for "suspended" status badge
2. **Admin API**: `GET /admin/tenants/<id>` — check `status` field
3. **Alerts**: Check `/admin/alerts` for "Customer suspended" Critical alerts

## Contacting the customer

1. Get customer email from admin panel customer detail page
2. Send payment failure notification explaining:
   - Their payment method on file failed
   - Their account is temporarily suspended
   - They need to update their payment method to restore access
3. Include a link to `/dashboard/billing` where they can update payment info

## Reactivating a customer

### Prerequisites
- Confirm the customer has updated their payment method in Stripe
- Verify the new payment method is valid (check Stripe dashboard)

### Steps

1. **Via admin panel**: Navigate to `/admin/customers/<id>` → click "Reactivate" button
2. **Via admin API**:
   ```bash
   curl -X POST https://api.flapjack.foo/admin/tenants/<id>/reactivate \
     -H "X-Admin-Key: $ADMIN_KEY"
   ```
3. Verify the customer can log in and access their indexes
4. Optionally trigger a re-billing run for the suspended period if needed

## Post-reactivation verification

1. Customer status should be "active" in admin panel
2. Customer should be able to access `/dashboard` without 403
3. Their indexes and deployments should still be intact (suspension does not delete data)
