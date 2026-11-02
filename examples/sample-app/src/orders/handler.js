import { listOrders } from './repository.js';
import { paginate, parsePagination } from '../lib/pagination.js';

export function handleListOrders(query = {}) {
  const parsed = parsePagination(query);
  if (parsed.error) return { status: 400, body: { error: parsed.error } };
  return { status: 200, body: paginate(listOrders(), parsed) };
}
