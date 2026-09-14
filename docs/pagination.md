# Pagination

What the API does with collections today, and how this client is built so the
same code stays correct if that changes.

## Today: no pagination

Collection endpoints return **every** matching record in one response, with no
`links.next`. There is no limit, no cursor, and no way to ask for a page. This
is a standing property of the API, not a temporary note: pagination is not
expected soon.

Consequences a caller has to know about:

- Listing a large collection fetches all of it — a real memory and latency
  hazard on a busy merchant. Filter aggressively.
- Invalid filters are **dropped rather than rejected** by the server. Combined
  with the above, a single typo in a filter key turns a narrow query into a
  full-collection fetch. `Edge::Query` refuses the shapes that would cause it.
- `page[*]` parameters are **accepted and ignored**. Asking for
  `page[limit]=10` today returns everything, with no error to say the request
  was not honoured — the same silent-drop failure mode as filters.

## What this client does

**Follow `links.next`; never construct a page URL.**

Against the API today there is no `links.next`, so a list yields one page and
stops. If the server starts paginating with links, the identical code
paginates. No client change, no version bump, no break for callers.

The public surface stays a generic `page:` hash until a pagination contract is
published. Exposing `limit:`/`after:`/`before:` keywords, or validating a page
size client-side, would couple this client's API to a design that does not
exist yet.

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

- A collection with no `links` at all — today's shape.
- A multi-page chain — a possible future shape.
- Relative `links.next`.
- Same-origin absolute `links.next`.
- Cross-origin `links.next`: refused, and the token is not sent.
- A cycle among links: terminates.
- `break` from inside `auto_paging_each`: stops fetching immediately.

## What `Edge::ListObject` does with all this

`#each` covers one page. `#auto_paging_each` walks them all. Today those are the
same thing, because there is only ever one page; they stop being the same if the
server starts paginating, and the distinction is in the API now so that no
caller has to change later.

Walking pages safely matters more than it might look, because a pagination link
is a URL chosen by the response and followed with a bearer token attached:

- Every link is resolved and origin-checked before it is followed. A
  cross-origin `next` raises `Edge::InsecureRedirectError` rather than handing
  the credential to whatever host the response named. The check lives in
  `Client#url_for` and nowhere else — two copies of a security rule eventually
  disagree.
- **Every** visited URL is remembered, not just the previous one, so a server
  answering `A -> B -> A` terminates instead of spinning. A repeated cursor
  **raises**. Stopping quietly would hand back a partial collection that looks
  exactly like a complete one, and the caller could not tell which records went
  missing.
- `max_auto_pages` is a second guard, for an unbounded chain of distinct URLs
  rather than a cycle. It also raises, and it comes from
  `Configuration#max_auto_pages` (default 1000) rather than from a constant of
  its own — a second copy of the limit is how the configured setting came to do
  nothing at all.
