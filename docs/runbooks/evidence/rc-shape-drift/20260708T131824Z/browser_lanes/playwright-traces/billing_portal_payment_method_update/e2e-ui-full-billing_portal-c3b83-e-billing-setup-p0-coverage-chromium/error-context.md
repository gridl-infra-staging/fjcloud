# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e-ui/full/billing_portal_payment_method_update.spec.ts >> Billing in-app payment-method updates >> saves a new payment method via the Stripe Payment Element on /console/billing/setup @p0_coverage
- Location: tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts:196:2

# Error details

```
TimeoutError: page.waitForURL: Timeout 60000ms exceeded.
=========================== logs ===========================
waiting for navigation until "load"
============================================================
```

# Page snapshot

```yaml
- generic [ref=e1]:
  - generic [ref=e2]:
    - generic:
      - region "Notifications alt+T"
    - generic [ref=e3]:
      - complementary [ref=e4]:
        - generic [ref=e6]: Flapjack Cloud
        - generic [ref=e7]:
          - navigation [ref=e8]:
            - link "Console" [ref=e9] [cursor=pointer]:
              - /url: /console
            - link "Indexes" [ref=e10] [cursor=pointer]:
              - /url: /console/indexes
            - link "Billing" [ref=e11] [cursor=pointer]:
              - /url: /console/billing
            - link "API Keys" [ref=e12] [cursor=pointer]:
              - /url: /console/api-keys
            - link "Logs" [ref=e13] [cursor=pointer]:
              - /url: /console/logs
            - link "Migrate" [ref=e14] [cursor=pointer]:
              - /url: /console/migrate
            - link "Account" [ref=e15] [cursor=pointer]:
              - /url: /console/account
          - generic [ref=e16]:
            - paragraph [ref=e17]: Help
            - generic [ref=e18]:
              - link "Support" [ref=e19] [cursor=pointer]:
                - /url: mailto:support@flapjack.foo
              - link "API Docs" [ref=e20] [cursor=pointer]:
                - /url: https://api.flapjack.foo/docs
      - generic [ref=e21]:
        - banner [ref=e22]:
          - generic [ref=e24]: Paid Plan
          - generic [ref=e25]:
            - generic [ref=e26]: Billing Portal 1783557471315-18gi3b5n
            - button "Logout" [ref=e28]
        - generic [ref=e30]:
          - generic [ref=e31]: BETA
          - generic [ref=e32]: Public beta.
          - link "View beta scope" [ref=e33] [cursor=pointer]:
            - /url: /beta
          - link "Send feedback" [ref=e34] [cursor=pointer]:
            - /url: mailto:support@flapjack.foo?subject=Flapjack%20Cloud%20beta%20feedback
          - link "Support" [ref=e35] [cursor=pointer]:
            - /url: mailto:support@flapjack.foo
        - main [ref=e36]:
          - generic [ref=e37]:
            - navigation "Billing navigation" [ref=e38]:
              - link "Payment Methods" [ref=e39] [cursor=pointer]:
                - /url: /console/billing
              - link "Invoices" [ref=e40] [cursor=pointer]:
                - /url: /console/billing/invoices
            - generic [ref=e41]:
              - heading "Add Payment Method" [level=1] [ref=e42]
              - generic [ref=e44]:
                - iframe [active] [ref=e47]:
                  - generic [ref=f7e7]:
                    - generic [ref=f7e8]:
                      - button "Card" [ref=f7e10] [cursor=pointer]:
                        - generic [ref=f7e17]: Card
                      - generic [ref=f7e18]:
                        - button "Pix" [expanded] [active] [ref=f7e19]:
                          - generic [ref=f7e25]: Pix
                        - generic [ref=f7e29]:
                          - generic [ref=f7e31]:
                            - generic [ref=f7e33]:
                              - generic [ref=f7e34]: Email
                              - textbox "Email" [ref=f7e37]
                            - generic [ref=f7e39]:
                              - generic [ref=f7e40]: CPF or CNPJ
                              - textbox "CPF or CNPJ" [ref=f7e43]:
                                - /placeholder: 000.000.000-00
                            - generic [ref=f7e45]:
                              - generic [ref=f7e46]: Full name
                              - textbox "Full name" [ref=f7e49]:
                                - /placeholder: First and last name
                            - paragraph [ref=f7e51]: You will be shown a QR code to scan to complete your purchase.
                            - paragraph [ref=f7e62]:
                              - text: This is an international purchase and may include a 3.5% IOF fee. By proceeding, you acknowledge and accept
                              - link "Ebanx’s terms and conditions" [ref=f7e63] [cursor=pointer]:
                                - /url: https://www.ebanx.com/pt-br/legal/consumidores/brasil/termos-para-processar-pagamentos/
                              - text: .
                          - button
                      - button "Klarna" [ref=f7e65] [cursor=pointer]:
                        - generic [ref=f7e74]: Klarna
                      - button "Cash App Pay" [ref=f7e76] [cursor=pointer]:
                        - generic [ref=f7e82]: Cash App Pay
                      - button "Kakao Pay" [ref=f7e84] [cursor=pointer]:
                        - generic [ref=f7e90]: Kakao Pay
                    - button "Additional Payment Methods" [ref=f7e93] [cursor=pointer]:
                      - generic [ref=f7e96]: More
                - generic [ref=e48]:
                  - link "Cancel" [ref=e49] [cursor=pointer]:
                    - /url: /console/billing
                  - button "Save payment method" [ref=e50]
  - iframe [ref=e52]:
    - button "Open Stripe Developer Tools" [ref=f8e5] [cursor=pointer]:
      - banner [ref=f8e8]:
        - generic "View Errors" [ref=f8e9]:
          - status [ref=f8e10]: "1"
        - img [ref=f8e11]
        - img [ref=f8e13]
```

# Test source

```ts
  160 | 			`set-default-form-${arrangedCustomer.nonDefaultPaymentMethodId}`
  161 | 		);
  162 | 		await expect(targetDefaultForm).toHaveCount(1);
  163 | 
  164 | 		await Promise.all([
  165 | 			setDefaultActionRequest,
  166 | 			setDefaultActionResponse,
  167 | 			targetDefaultForm.getByRole('button', { name: 'Set as default' }).click()
  168 | 		]);
  169 | 
  170 | 		// Server-owned backend contract coverage lives in billing.server.test.ts
  171 | 		// because `/billing/*` calls are made by `+page.server.ts`, not by the browser.
  172 | 
  173 | 		const actionRequest = await setDefaultActionRequest;
  174 | 		const requestBody = actionRequest.postData() ?? '';
  175 | 		expect(requestBody).toContain(
  176 | 			`paymentMethodId=${encodeURIComponent(arrangedCustomer.nonDefaultPaymentMethodId)}`
  177 | 		);
  178 | 
  179 | 		await expect(page).toHaveURL(/\/console\/billing/);
  180 | 		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
  181 | 		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
  182 | 		await expect(page.getByTestId('payment-element')).toBeVisible();
  183 | 		await expect(
  184 | 			page.getByTestId(
  185 | 				`set-default-payment-method-id-${arrangedCustomer.nonDefaultPaymentMethodId}`
  186 | 			)
  187 | 		).toHaveCount(0);
  188 | 		await expect(page.getByText('Default', { exact: true })).toHaveCount(1);
  189 | 		const currentDefaultPaymentMethodId = await waitForStripeDefaultPaymentMethod(
  190 | 			arrangedCustomer.stripeCustomerId,
  191 | 			arrangedCustomer.expectedDefaultPaymentMethodId
  192 | 		);
  193 | 		expect(currentDefaultPaymentMethodId).toBe(arrangedCustomer.expectedDefaultPaymentMethodId);
  194 | 	});
  195 | 
  196 | 	test('saves a new payment method via the Stripe Payment Element on /console/billing/setup @p0_coverage', async ({
  197 | 		page,
  198 | 		arrangeBillingPortalCustomer,
  199 | 		waitForStripeDefaultPaymentMethod,
  200 | 		loginAs
  201 | 	}) => {
  202 | 		test.setTimeout(180_000);
  203 | 		const arrangedCustomer = await arrangeBillingPortalCustomer();
  204 | 
  205 | 		await loginWithFixtureCredentials(
  206 | 			page,
  207 | 			arrangedCustomer.email,
  208 | 			arrangedCustomer.password,
  209 | 			loginAs
  210 | 		);
  211 | 		await gotoBillingPageWithSessionRecovery(
  212 | 			page,
  213 | 			arrangedCustomer.email,
  214 | 			arrangedCustomer.password,
  215 | 			loginAs
  216 | 		);
  217 | 		await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
  218 | 
  219 | 		if (arrangedCustomer.stripeCustomerId.startsWith('cus_local_')) {
  220 | 			test.skip(
  221 | 				true,
  222 | 				'Local Stripe mode does not expose the hosted Payment Element; initial-save proof requires Stripe test-mode credentials.'
  223 | 			);
  224 | 		}
  225 | 
  226 | 		// Baseline: arrangeBillingPortalCustomer attaches one Visa (pm_card_visa,
  227 | 		// last4=4242) as the default PM.
  228 | 		const visaRowLocator = page.getByText('Visa ending in 4242');
  229 | 		await expect(visaRowLocator).toHaveCount(1);
  230 | 
  231 | 		await page.goto('/console/billing/setup');
  232 | 		await expect(page.getByRole('heading', { name: 'Add Payment Method' })).toBeVisible();
  233 | 		await expect(page.getByTestId('payment-element')).toBeVisible();
  234 | 
  235 | 		// The Stripe Payment Element mounts a Stripe-hosted iframe inside the
  236 | 		// `payment-element` testid container. The iframe `name` is dynamic
  237 | 		// (`__privateStripeFrame<n>`), so target it by prefix from inside the host.
  238 | 		const stripeFrame = page
  239 | 			.getByTestId('payment-element')
  240 | 			.frameLocator('iframe[name^="__privateStripeFrame"]');
  241 | 
  242 | 		const cardMethodButton = stripeFrame.getByRole('button', { name: /^Card$/i });
  243 | 		await expect(cardMethodButton).toBeVisible({ timeout: 30_000 });
  244 | 		await cardMethodButton.click();
  245 | 
  246 | 		const cardNumberField = stripeFrame.getByRole('textbox', { name: /Card number/i });
  247 | 		await expect(cardNumberField).toBeVisible({ timeout: 30_000 });
  248 | 		await cardNumberField.fill('4242424242424242');
  249 | 
  250 | 		await stripeFrame.getByRole('textbox', { name: /Expiration/i }).fill('1230');
  251 | 		await stripeFrame.getByRole('textbox', { name: /CVC|Security code/i }).fill('123');
  252 | 
  253 | 		await selectStripeCardCountry(stripeFrame);
  254 | 
  255 | 		// Postal/ZIP collection depends on Stripe Element config + customer
  256 | 		// billing-address state. Fill only when the field renders.
  257 | 		await fillStripePostalCodeWhenPresent(stripeFrame);
  258 | 
  259 | 		await page.getByRole('button', { name: 'Save payment method' }).click();
> 260 | 		await page.waitForURL(/\/console\/billing(?:\?|$)/, { timeout: 60_000 });
      |              ^ TimeoutError: page.waitForURL: Timeout 60000ms exceeded.
  261 | 
  262 | 		// End-effect: the setup flow returns to the billing page and preserves the
  263 | 		// existing default card. Stripe may or may not de-duplicate the identical
  264 | 		// test card fingerprint, so accept count 1 (de-duplicated) or 2 (both kept).
  265 | 		await expect(page.getByRole('heading', { name: 'Payment methods' })).toBeVisible();
  266 | 		await expect(visaRowLocator.first()).toBeVisible({ timeout: 30_000 });
  267 | 
  268 | 		// Stripe-API end-effect: the customer's default PM should still be the
  269 | 		// fixture-attached default (Stripe does not auto-promote SetupIntent PMs).
  270 | 		const defaultPaymentMethodId = await waitForStripeDefaultPaymentMethod(
  271 | 			arrangedCustomer.stripeCustomerId,
  272 | 			arrangedCustomer.defaultPaymentMethodId
  273 | 		);
  274 | 		expect(defaultPaymentMethodId).toBe(arrangedCustomer.defaultPaymentMethodId);
  275 | 	});
  276 | });
  277 | 
```