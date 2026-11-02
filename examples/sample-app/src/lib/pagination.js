export const DEFAULT_PAGE_SIZE = 20;
export const MAX_PAGE_SIZE = 100;

/**
 * Parse page/pageSize query parameters.
 * @returns {{ page: number, pageSize: number } | { error: string }}
 */
export function parsePagination(query) {
  const page = query.page === undefined ? 1 : Number(query.page);
  const pageSize = query.pageSize === undefined ? DEFAULT_PAGE_SIZE : Number(query.pageSize);
  if (!Number.isInteger(page) || page < 1) return { error: 'page must be a positive integer' };
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
    return { error: `pageSize must be an integer between 1 and ${MAX_PAGE_SIZE}` };
  }
  return { page, pageSize };
}

/** Slice items into one page and describe it. */
export function paginate(items, { page, pageSize }) {
  const start = (page - 1) * pageSize;
  return {
    data: items.slice(start, start + pageSize),
    pagination: { page, pageSize, total: items.length, totalPages: Math.ceil(items.length / pageSize) },
  };
}
