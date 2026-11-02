import { getProduct, listProducts } from './repository.js';

export function handleListProducts() {
  return { status: 200, body: { data: listProducts() } };
}

export function handleGetProduct(id) {
  const product = getProduct(Number(id));
  if (!product) return { status: 404, body: { error: 'Not found' } };
  return { status: 200, body: { data: product } };
}
