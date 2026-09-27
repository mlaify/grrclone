# The usage document: `<url>/.usage/usage.json`

grrclone shows how much of a remote is used when the remote can say. The first source is
rclone's own `about` — for WebDAV that is the RFC 4331 quota properties, for drive-like
backends the provider's API — and grrclone adds nothing backend-specific to it. Many small
WebDAV servers report nothing that way, and RFC 4331 cannot express more than one pair of
numbers. This document is the fallback for them: a tiny JSON file the app fetches **with the
same credentials it already uses for the share**, at a fixed relative path.

    GET <remote url>/.usage/usage.json
    Authorization: Basic <the remote's user and password>

A `200` with a JSON `Content-Type` and the document below means the server supports it.
Anything else — `401`, `404`, an HTML page — means it does not, and grrclone shows "This
storage does not report usage." It never retries in a loop and never treats the absence as an
error. Plain `http://` remotes are not asked at all.

## Version 1

```json
{
  "version": 1,
  "user": "alice",
  "generated_at": "2026-09-22T18:00:00Z",
  "categories": [
    {"id": "files",  "label": "Files",  "used_bytes": 1076546999296,
     "soft_limit_bytes": 1924145348608, "hard_limit_bytes": 2199023255552, "grace": null},
    {"id": "photos", "label": "Photos", "used_bytes": 170688508942,
     "soft_limit_bytes": null, "hard_limit_bytes": 536870912000, "grace": null}
  ]
}
```

| field | meaning |
|---|---|
| `version` | integer; grrclone ignores documents with a version it does not know |
| `user` | the account the credentials resolved to; informational |
| `generated_at` | RFC 3339 UTC; documents may be minutes to an hour old |
| `categories[]` | one entry per independently limited pool, in display order |
| `id` | stable token for the pool |
| `label` | text to show; defaults to `id` |
| `used_bytes` | required |
| `soft_limit_bytes` | `null` when the pool has no soft limit |
| `hard_limit_bytes` | `null` means **no cap** — shown as a number, not as a full bar |
| `grace` | `null`, or human text such as `"6days"` meaning the soft limit is exceeded and writes stop when it runs out |

grrclone draws one bar per category that has a hard limit, marks it orange past the soft
limit or at 85 %, and prints the grace text when present. Servers should keep the document
under a few kilobytes and answer with `Cache-Control: no-store`.

## Why the remote's own credentials

Because the app already holds them, and because a document that anyone can read would leak
how much a named user stores. The request carries them in an `Authorization` header, never in
the URL, and they are revealed from rclone's obscured form for that one request only.

## A tile in the sign-in portal

The same numbers are useful to people who never install grrclone. A server that writes the
JSON can render it as a small HTML page too, behind its web single sign-on instead of the share's
device password, and link that page from the portal people already sign in to. In Authentik that
is an Application with no provider — a bookmark tile:

| field | value |
|---|---|
| Name | `Storage usage` |
| Slug | `storage-usage` |
| Group | whatever section the storage tiles sit in |
| Launch URL | the page, e.g. `https://files.example.com/usage` |
| Icon | `docs/images/grrclone-icon-256.png` from this repository, uploaded to Authentik's file storage (see below) |
| Policy binding | the same group that can open the storage service itself |

Which person's figures the page shows has to come from the proxy's authenticated identity (for
example the `X-Authentik-Username` header set by forward auth), never from a query parameter
the browser controls. With no provider attached, the tile is only a link: the page stays
protected by its own forward auth, and the binding decides who sees the tile.

Recent Authentik releases keep icons in their own file storage and serve them with a short-lived
signed URL, so an uploaded icon keeps working when the CDN that hosts most dashboard icons is
unreachable. Upload the PNG on the admin interface's **Files** page (or place it beneath `media/public/` in the
`/data` volume), then set the Application's icon to that file's name.

## Implementing it

Any server can: write the JSON hourly from whatever accounts for the space — filesystem
quotas, an application database, `du` — and serve it behind the share's existing
authentication. A reference implementation using Caddy and ext4 user quotas lives in the
author's infrastructure repository.
