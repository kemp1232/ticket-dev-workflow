import test from 'node:test';
import assert from 'node:assert/strict';
import { handleGetProduct, handleListProducts } from '../src/products/handler.js';

test('lists all products', () => {
  const res = handleListProducts();
  assert.equal(res.status, 200);
  assert.equal(res.body.data.length, 12);
});

test('gets one product', () => {
  const res = handleGetProduct('3');
  assert.equal(res.status, 200);
  assert.equal(res.body.data.name, 'Fountain pen');
});

test('returns 404 for an unknown product', () => {
  const res = handleGetProduct('999');
  assert.equal(res.status, 404);
  assert.equal(res.body.error, 'Not found');
});
