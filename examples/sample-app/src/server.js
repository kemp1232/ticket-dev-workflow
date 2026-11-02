import http from 'node:http';
import { handleGetProduct, handleListProducts } from './products/handler.js';
import { handleListOrders } from './orders/handler.js';

export function route(method, url) {
  const { pathname, searchParams } = new URL(url, 'http://localhost');
  const query = Object.fromEntries(searchParams);
  if (method !== 'GET') return { status: 405, body: { error: 'Method not allowed' } };
  if (pathname === '/products') return handleListProducts(query);
  const match = pathname.match(/^\/products\/(\d+)$/);
  if (match) return handleGetProduct(match[1]);
  if (pathname === '/orders') return handleListOrders(query);
  return { status: 404, body: { error: 'Not found' } };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  http
    .createServer((req, res) => {
      const { status, body } = route(req.method, req.url);
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    })
    .listen(process.env.PORT || 3000);
}
