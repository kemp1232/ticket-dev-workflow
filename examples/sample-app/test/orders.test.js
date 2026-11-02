import test from 'node:test';
import assert from 'node:assert/strict';
import { handleListOrders } from '../src/orders/handler.js';

test('paginates orders with defaults', () => {
  const res = handleListOrders({});
  assert.equal(res.status, 200);
  assert.equal(res.body.data.length, 20);
  assert.deepEqual(res.body.pagination, { page: 1, pageSize: 20, total: 45, totalPages: 3 });
});

test('returns the last partial page', () => {
  const res = handleListOrders({ page: '3', pageSize: '20' });
  assert.equal(res.body.data.length, 5);
});

test('rejects an invalid page size', () => {
  const res = handleListOrders({ pageSize: '500' });
  assert.equal(res.status, 400);
});
