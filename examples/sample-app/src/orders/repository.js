const orders = Array.from({ length: 45 }, (_, i) => ({
  id: i + 1,
  productId: (i % 12) + 1,
  quantity: (i % 3) + 1,
}));

export function listOrders() {
  return orders;
}
