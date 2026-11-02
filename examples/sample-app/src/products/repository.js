const products = [
  { id: 1, name: 'Desk lamp', priceCents: 2999 },
  { id: 2, name: 'Notebook', priceCents: 499 },
  { id: 3, name: 'Fountain pen', priceCents: 4500 },
  { id: 4, name: 'Monitor stand', priceCents: 3999 },
  { id: 5, name: 'USB-C hub', priceCents: 5499 },
  { id: 6, name: 'Desk mat', priceCents: 1999 },
  { id: 7, name: 'Cable ties', priceCents: 299 },
  { id: 8, name: 'Webcam', priceCents: 6999 },
  { id: 9, name: 'Headphone hook', priceCents: 1299 },
  { id: 10, name: 'Sticky notes', priceCents: 349 },
  { id: 11, name: 'Mechanical pencil', priceCents: 899 },
  { id: 12, name: 'Laptop sleeve', priceCents: 2499 },
];

export function listProducts() {
  return products;
}

export function getProduct(id) {
  return products.find((p) => p.id === id);
}
