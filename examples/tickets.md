# Example tickets

Three tickets at different levels, showing what `/ticket-dev` does with each. The `route.sh` outputs are real outputs of the script for the inputs shown (trimmed to the interesting keys). The explorer findings are illustrative: in your repository they come from your code.

## 1. Simple frontend fix (LOW, light route)

```
/ticket-dev Fix the "Add to card" typo on the product page button; it should say "Add to cart". Start with @src/components/ProductCard.tsx
```

1. Triage finds no risk keywords and the ticket names the file, so the orchestrator takes the **fast path**: no explorer, it greps for `Add to card` and reads those lines itself.
2. Routing inputs: one file, one module, no uncertainty, `--tests na` (copy change).

   ```
   complexity=LOW  risk=LOW  route=light  model=haiku
   approval=none   gpt_review=skip   verification=targeted
   reasons=files=1(+0); modules=1(+0); uncertainty=none(+0)
   ```

3. Compact contract, no gate, implementer runs on haiku, verifier runs the component's tests (or SKIPs with a reason if there are none), report.

If the label lived in a shared translation file used by checkout, triage would have flagged nothing, but the orchestrator should still notice the wider blast radius and pass `--files`/`--modules` accordingly. Typing "checkout" in the ticket would raise the `payments` flag, which the orchestrator dismisses with a reason such as `--dismiss "payments:label text only, no payment logic"`.

## 2. Moderate API feature (MEDIUM, standard route)

```
/ticket-dev Implement pagination on the existing products API
```

1. Triage raises `public-api(api)`, so the explorer (haiku) runs. In the bundled `examples/sample-app` it reports that `/orders` already paginates with `parsePagination`/`paginate` in `src/lib/pagination.js`, that `/products` returns `{ data }` from `src/products/handler.js`, and that `test/products.test.js` covers the handler.
2. The orchestrator confirms `public-api`: the response gains a `pagination` object and the default page size changes what un-paginated clients receive. Following the orders pattern settles the format, so that becomes an assumption, not a blocking question.

   ```
   complexity=MEDIUM  risk=MEDIUM  route=standard  model=sonnet
   approval=none      gpt_review=skip  verification=standard
   reasons=files=3(+1); modules=1(+0); uncertainty=low(+1); risk MEDIUM: public-api
   ```

3. Standard contract (acceptance criteria such as "`GET /products?page=2&pageSize=5` returns items 6-10 with pagination metadata" and "invalid pageSize returns 400 like /orders"), no approval gate, implementer on sonnet, verifier runs `node --test test/products.test.js` and then `npm test`.

With `--plan-only` the run stops after the contract and changes nothing.

## 3. Complex database and external integration (HIGH, complex route)

```
/ticket-dev Sync Stripe subscription status into the users table via webhooks: add a subscription_status column with a migration and backfill existing users
```

1. Triage raises `migration`, `payments` and `external-integration`. The explorer maps the users model, the migration tool and folder, any existing webhook handling, and how Stripe is already called.
2. The orchestrator confirms all three, adds `concurrency` (webhook retries need idempotent handling), and counts one blocking decision: what to do with users whose Stripe customer cannot be found during the backfill.

   ```
   complexity=HIGH  risk=HIGH  route=complex  model=opus
   approval=required  blocking_questions=1  gpt_review=offer  verification=broad
   reasons=files=9(+2); modules=3(+1); uncertainty=high(+2); external-integration(+1); concurrency(+1); migration(+1); risk HIGH: payments,migration
   ```

3. Gates, in order: the blocking question; the opus implementer's PLAN (steps, tests, risks, rollback); explicit approval; and a one-line offer of an optional GPT review, because uncertainty is high and a decision is open.
4. After approval, the implementer writes the migration file, handler and tests, but the guard blocks applying the migration (`prisma migrate`, `rails db:migrate`, ...) and any Stripe CLI or API call. Those are listed in the report for the developer to run.
5. Broad verification: targeted tests, typecheck, lint, the full suite and the build.

## Overrides

```
/ticket-dev --model opus Add retry with backoff to the email sender
/ticket-dev --plan-only --gpt Split the reporting service into read and write paths
```

`--model` forces the implementation model; if it is below the computed route on a HIGH-risk ticket, the report says so. `--gpt` asks for a GPT review package even when it was not suggested.
