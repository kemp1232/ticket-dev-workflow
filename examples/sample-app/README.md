# sample-products-api

Fixture repository for the ticket-dev smoke test. Plain Node.js (18+), no dependencies.

- `GET /products`, `GET /products/:id` - src/products
- `GET /orders?page=&pageSize=` - src/orders (paginated with src/lib/pagination.js)

Run the tests with `npm test`.
