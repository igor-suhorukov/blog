# blog

Igor Suhorukov's blog, published with GitHub Pages at <https://igor-suhorukov.github.io/blog/>
(Settings → Pages → Deploy from a branch → `main`, `/ (root)`).

## Planet PostgreSQL

[Planet PostgreSQL](https://planet.postgresql.org/) syndicates
[`feed/postgresql.xml`](feed/postgresql.xml), an Atom feed that holds only the
posts tagged `postgresql`, because the
[Planet policy](https://www.postgresql.org/about/policies/planet-postgresql/)
accepts only English posts about PostgreSQL. `/feed.xml` carries every post.

Registered feed URL: <https://igor-suhorukov.github.io/blog/feed/postgresql.xml>

## Writing a post

- Add `_posts/YYYY-MM-DD-slug.md` with `title` and `tags` in the front matter;
  tag it `postgresql` to send it to Planet PostgreSQL.
- Give it `date: YYYY-MM-DD HH:MM:SS +0700`, the time you push it. Without a
  time the feed says midnight UTC, and Planet PostgreSQL shows and sorts the
  post by that. Planet stores a post once and never rereads its date, so set
  the time before the first push. Don't use a time later than the push:
  GitHub Pages skips posts dated in the future.
- Feed readers and Planet do not run JavaScript, so Mermaid diagrams are
  embedded as PNGs with absolute URLs. Keep the sources in
  `_diagrams/<slug>/*.mmd` and render them to `assets/posts/<slug>/` with
  `scripts/render-diagrams.sh <slug>` (needs Docker).

## Local preview

```sh
bundle install
bundle exec jekyll serve
```

Then open <http://localhost:4000/blog/>.
