# Pagination

Two different behaviours matter to this client: what production does today, and
what an unmerged branch proposes. They are recorded separately on purpose. The
client is built so the same code is correct under both.

## Production today: no pagination

Collection endpoints return **every** matching record in one response, with no
`links.next`. There is no limit, no cursor, and no way to ask for a page.

Verified on `main` (`8372ac06c76b5273ec36c365079759fdaa83010e`):
`PhoenixJSONAPI.Conn.put_data/2` runs the query and renders the result; nothing
paginates and no pagination links are emitted.

Consequences a caller has to know about:

- Listing a large collection fetches all of it — a real memory and latency
  hazard on a busy merchant. Filter aggressively.
- Invalid filters and sorts are **dropped rather than rejected** by the server.
  Combined with the above, a single typo in a filter key turns a narrow query
  into a full-collection fetch.
- `page[*]` parameters are **parsed and then ignored**
  (`jsonapi_parser_plug.ex:132` builds a `pagination` map that nothing reads).
  So asking for `page[limit]=10` today returns everything, with no error to say
  the request was not honoured — the same silent-drop failure mode as filters.

## Proposed: opaque cursors

Branch `edg-1498-implement-pagination-in-to-the-jsonapi-interface`, in
`ept/lib/phoenix_jsonapi/pagination.ex`. Not merged, not deployed.

| Parameter | Behaviour |
| --- | --- |
| `page[limit]` | Default 50, maximum 100. Outside 1..100 is a 400 |
| `page[after]` | Opaque forward cursor |
| `page[before]` | Opaque backward cursor |

- `page[after]` and `page[before]` together is a 400.
- Any other `page[*]` key is rejected: `Unsupported pagination parameter`.
- Errors arrive as JSON:API error objects with `source.parameter` set to
  `page[limit]` and so on.
- Cursor fields are derived from `sort`; with no sort they default to
  `inserted_at DESC, id DESC`.
- **Sorting by a relationship attribute is rejected** for paginated
  collections.
- Response `links` carries `self`, plus `prev` and `next` only when non-nil.

Cursors are opaque and valid only for the sort that produced them. They are not
record IDs and must never be constructed by a client.

### The snapshot disagrees with the branch

`contract/openapi.json` still advertises `page[size]`, `page[number]` and
`page[offset]` in `components/parameters`. That is inherited boilerplate which
the branch's `openapi.ex` replaces. Ignore it; it describes nothing that has
ever worked.

## What this client does

**Follow `links.next`; never construct a page URL.**

Against production there is no `links.next`, so a list yields one page and
stops. When the branch ships, the identical code paginates. No client change,
no version bump, no break for callers.

The public surface stays a generic `page:` hash until the server contract is
merged and deployed. Exposing `limit:`/`after:`/`before:` keywords, or
validating `limit <= 100` client-side, would couple this client's API to a
branch that production does not enforce and whose design can still change.

### Following links safely

Following `links.next` verbatim with the authenticated connection is a
credential-exfiltration path: a response, proxy or test stub that returns an
absolute URL on another origin would be handed the bearer token. So:

- Relative links resolve against the configured base URL.
- Absolute links must match the configured scheme, host and effective port.
  Cross-origin pagination links and cross-origin redirects are refused.
- Every visited normalized URL is tracked, not just the previous one, so
  `A -> B -> A` terminates.
- `max_auto_pages` (default 1000) is a second, independent guard.

### Tests this behaviour needs

- A collection with no `links` at all — production shape.
- A multi-page chain — future shape.
- Relative `links.next`.
- Same-origin absolute `links.next`.
- Cross-origin `links.next`: refused, and the token is not sent.
- A cycle among links: terminates.
- `break` from inside `auto_paging_each`: stops fetching immediately.
