"""Live-web quality examples for a loop bar.

Search the public web for real references (repos, posts, products, papers)
and persist the ones the human selected as the comparison set a builder
and critic must open — not snippets, not memory.
"""

from __future__ import annotations

import hashlib
import json
import html as htmlmod
import re
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0.0.0 Safari/537.36"
)
DDG_HTML = "https://html.duckduckgo.com/html/"
BING_HTML = "https://www.bing.com/search"

JUNK_HOSTS = {
    "duckduckgo.com",
    "html.duckduckgo.com",
    "bing.com",
    "www.bing.com",
    "login.live.com",
    "login.microsoftonline.com",
    "accounts.google.com",
    "signup.live.com",
    "consent.yahoo.com",
    "consent.google.com",
}

LOGIN_MARKERS = (
    "/login",
    "/signin",
    "/signup",
    "/account/login",
    "/oauth",
    "accounts.google",
    "login.microsoft",
)

HOMEPAGE_HOSTS = {
    "github.com",
    "gitlab.com",
    "arxiv.org",
    "wikipedia.org",
    "en.wikipedia.org",
    "twitter.com",
    "x.com",
    "linkedin.com",
    "facebook.com",
    "reddit.com",
    "medium.com",
    "youtube.com",
    "www.youtube.com",
}


class ExampleError(RuntimeError):
    pass


def _strip_html(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = htmlmod.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _id_for(url: str) -> str:
    return "ex_" + hashlib.sha1(url.encode("utf-8", "replace")).hexdigest()[:10]


def unwrap_url(url: str) -> str:
    raw = (url or "").strip()
    if raw.startswith("//"):
        raw = "https:" + raw
    parsed = urlparse(raw)
    host = (parsed.netloc or "").lower()
    if "duckduckgo.com" in host:
        qs = parse_qs(parsed.query)
        uddg = (qs.get("uddg") or [""])[0]
        if uddg:
            return unquote(uddg)
    return raw


GITHUB_UA = "CyberPong"
GITHUB_SEARCH = "https://api.github.com/search/repositories"

DROP_VERBS = {
    "review", "reviews", "reviewed", "make", "made", "look", "looking",
    "update", "updated", "please", "help", "check", "see", "try", "want",
    "need", "ensure", "create", "build", "built", "ship", "write", "wrote",
}

STOPWORDS = {
    "the", "a", "an", "and", "or", "as", "of", "to", "for", "with", "from",
    "into", "on", "in", "at", "by", "is", "are", "be", "been", "being",
    "this", "that", "these", "those", "it", "its", "new", "locally",
    "possible", "their", "own", "based", "etc", "as", "well", "also",
    "very", "more", "most", "than", "then", "them", "they", "you", "your",
    "our", "we", "i", "me", "my", "do", "does", "did", "not", "no",
    "so", "if", "when", "while", "just", "like", "via", "using",
    "software", "choosing",
}

LISTICLE_TEXT = re.compile(
    r"(?i)\b(best|top\s*\d+|alternatives?|vs\.?|roundup|compared|comparison)\b"
)
LISTICLE_PATH_MARKERS = (
    "/tools/",
    "/best-",
    "/top-",
    "/alternatives",
    "/learn/article",
    "/software/",
)
GITHUB_NOISE = {
    "topics", "search", "explore", "orgs", "features", "marketplace",
    "collections", "trending", "settings", "login", "signup", "about",
    "pricing", "enterprise", "customer-stories", "readme", "issues",
    "pulls", "notifications", "stars", "sponsors",
}


def github_repo_key(url: str) -> str | None:
    parsed = urlparse(unwrap_url(url))
    host = (parsed.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if host not in {"github.com", "www.github.com"}:
        return None
    parts = [p for p in (parsed.path or "").strip("/").split("/") if p]
    if len(parts) < 2:
        return None
    if parts[0].lower() in GITHUB_NOISE:
        return None
    if parts[1].lower() in GITHUB_NOISE:
        return None
    return f"{parts[0]}/{parts[1]}".lower()


def looks_like_docs(url: str, host: str = "") -> bool:
    host = (host or host_of(url)).lower()
    path = (urlparse(url).path or "").lower()
    if host.startswith("docs.") or host.startswith("doc."):
        return True
    if host.endswith(".readthedocs.io") or host == "readthedocs.io":
        return True
    return any(m in path for m in ("/docs/", "/documentation/", "/guide/", "/manual/"))


def is_listicle(url: str, title: str = "", snippet: str = "") -> bool:
    parsed = urlparse(unwrap_url(url))
    path = (parsed.path or "").lower()
    blob = f"{title} {url} {snippet}"
    if LISTICLE_TEXT.search(blob):
        return True
    if any(m in path for m in LISTICLE_PATH_MARKERS):
        return True
    if "/resources/" in path and re.search(
        r"(platform|tool|best|top|alternativ|roundup|compar|list)", path
    ):
        return True
    return False


def guess_kind(url: str, host: str = "", title: str = "") -> str:
    host = (host or urlparse(url).netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if github_repo_key(url):
        return "repo"
    if "gitlab.com" in host:
        parts = [p for p in (urlparse(url).path or "").strip("/").split("/") if p]
        if len(parts) >= 2:
            return "repo"
    if "arxiv.org" in host:
        return "paper"
    if looks_like_docs(url, host):
        return "page"
    path = (urlparse(url).path or "").rstrip("/")
    if not is_listicle(url, title) and path.count("/") <= 1:
        return "product"
    return "page"


def distill_intents(query: str, *, max_intents: int = 4) -> list[str]:
    """Turn a long brief into 2–4 short search intents. Short queries stay intact."""
    q = str(query or "").strip()
    if not q:
        return []
    words = re.findall(r"[A-Za-z][A-Za-z0-9.+#_-]{1,}", q)
    low = [w.lower().strip(".-_+#") for w in words]
    low = [w for w in low if w]
    if len(low) <= 8:
        return [q]
    drop = DROP_VERBS | STOPWORDS
    kept = [w for w in low if w not in drop and len(w) > 2]
    tokens = set(kept)
    intents: list[str] = []

    def add(item: str) -> None:
        item = " ".join(item.split())
        if item and item.lower() not in {x.lower() for x in intents}:
            intents.append(item)

    if tokens & {"agent", "agents", "multi-agent", "multiagent"} and tokens & {
        "graph", "loop", "loops", "orchestration", "orchestrate"
    }:
        add("agent orchestration graph")
    if tokens & {"agent", "agents"} and tokens & {
        "tmux", "terminal", "terminals", "spawn", "spawning"
    }:
        add("multi-agent tmux")
    if tokens & {"agent", "agents"} and tokens & {"loop", "loops"}:
        add("agent loop github")
    if tokens & {"orchestrat", "orchestration", "orchestrate"}:
        add("agent orchestration")
    if "tmux" in tokens:
        add("multi-agent tmux")

    if len(intents) < 2:
        for a, b in zip(kept, kept[1:]):
            if a == b:
                continue
            bg = f"{a} {b}"
            if any(k in bg for k in ("graph", "agent", "loop", "orchestr", "tmux", "terminal")):
                add(bg)
            if len(intents) >= max_intents:
                break

    if not intents and kept:
        add(" ".join(kept[:4]))
        if len(kept) > 4:
            add(" ".join(kept[4:8]))
    return intents[: max(1, int(max_intents or 4))] or [q]


def host_of(url: str) -> str:
    host = (urlparse(url).netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def is_junk(url: str) -> bool:
    u = (url or "").strip()
    if not u or u.startswith("javascript:") or u.startswith("#"):
        return True
    parsed = urlparse(u)
    host = (parsed.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if not host or host in JUNK_HOSTS:
        return True
    low = u.lower()
    if any(m in low for m in LOGIN_MARKERS):
        return True
    path = (parsed.path or "").rstrip("/")
    if not path:
        if host in HOMEPAGE_HOSTS or not parsed.query:
            return True
    return False


def example_from_url(url: str, *, title: str = "", snippet: str = "", kind: str = "") -> dict[str, Any]:
    url = unwrap_url(url)
    host = host_of(url)
    title = _strip_html(title) or host or url
    return {
        "id": _id_for(url),
        "title": title,
        "url": url,
        "host": host,
        "snippet": _strip_html(snippet),
        "kind": kind or guess_kind(url, host),
    }


def normalize_selected(selected: Any) -> list[dict[str, Any]]:
    """Accept URLs, dicts, or a comma-separated string. Dedup by URL."""
    raw: list[Any] = []
    if selected is None:
        raw = []
    elif isinstance(selected, str):
        raw = [p.strip() for p in selected.split(",") if p.strip()]
    elif isinstance(selected, (list, tuple)):
        raw = list(selected)
    else:
        raw = [selected]
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in raw:
        if isinstance(item, dict):
            url = unwrap_url(str(item.get("url") or item.get("href") or item.get("link") or ""))
            if not url or url in seen or is_junk(url):
                # Allow an explicit selected URL even if it looks like a homepage —
                # the human picked it. Only skip empty / javascript.
                if not url or url.startswith("javascript:"):
                    continue
            if url in seen:
                continue
            seen.add(url)
            host = str(item.get("host") or "") or host_of(url)
            out.append(
                {
                    "id": str(item.get("id") or _id_for(url)),
                    "title": _strip_html(str(item.get("title") or "")) or host or url,
                    "url": url,
                    "host": host,
                    "snippet": _strip_html(str(item.get("snippet") or item.get("body") or "")),
                    "kind": str(item.get("kind") or "") or guess_kind(url, host),
                }
            )
        else:
            url = unwrap_url(str(item or "").strip())
            if not url or url in seen or url.startswith("javascript:"):
                continue
            seen.add(url)
            out.append(example_from_url(url))
    return out


def format_prompt_block(selected: Any) -> str:
    rows = normalize_selected(selected)
    if not rows:
        return ""
    lines = [
        "## Quality examples (the bar)",
        "Open these. Compare the artifact to them. Do not grade from memory.",
    ]
    for r in rows:
        lines.append(f"- {r['title']} — {r['url']}")
    return "\n".join(lines)


def write_bar(session: str, goal_id: str, query: str, selected: Any) -> Path:
    """Write a markdown bar listing the selected examples as the comparison set."""
    from .paths import ensure_layout, sessions_dir

    ensure_layout(session)
    goals = sessions_dir(session) / "goals"
    goals.mkdir(parents=True, exist_ok=True)
    gid = str(goal_id or "goal").strip() or "goal"
    path = goals / f"{gid}-examples.md"
    rows = normalize_selected(selected)
    lines = [
        "# Quality examples (the bar)",
        "",
        f"Query: {query}",
        f"Goal: {gid}",
        "",
        "Critics must **open these URLs**. Do not grade from the snippet or from memory.",
        "Compare the artifact to the live page.",
        "",
        "## Comparison set",
        "",
    ]
    if not rows:
        lines.append("(no examples selected)")
        lines.append("")
    for r in rows:
        lines.append(f"### {r['title']}")
        lines.append(f"- {r['title']} — {r['url']}")
        lines.append(f"- host: {r['host']}")
        lines.append(f"- kind: {r['kind']}")
        if r.get("snippet"):
            lines.append(f"- snippet (do not trust): {r['snippet']}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def _finalize(rows: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in rows:
        if not isinstance(raw, dict):
            continue
        url = unwrap_url(str(raw.get("url") or raw.get("href") or raw.get("link") or ""))
        if not url or url in seen or is_junk(url):
            continue
        seen.add(url)
        out.append(
            example_from_url(
                url,
                title=str(raw.get("title") or ""),
                snippet=str(raw.get("snippet") or raw.get("body") or ""),
                kind=str(raw.get("kind") or ""),
            )
        )
        if len(out) >= max(1, int(limit or 8)):
            break
    return out


class _DDGParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.results: list[dict[str, str]] = []
        self._in_title = False
        self._in_snip = False
        self._href = ""
        self._title: list[str] = []
        self._snip: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        d = {k: (v or "") for k, v in attrs}
        cls = d.get("class") or ""
        if tag == "a" and "result__a" in cls.split():
            self._in_title = True
            self._href = d.get("href") or ""
            self._title = []
        elif "result__snippet" in cls.split():
            self._in_snip = True
            self._snip = []

    def handle_endtag(self, tag: str) -> None:
        if self._in_title and tag == "a":
            self._in_title = False
            title = _strip_html("".join(self._title))
            url = unwrap_url(self._href)
            if url and title:
                self.results.append({"title": title, "url": url, "snippet": ""})
            self._href = ""
        if self._in_snip and tag in {"a", "span", "div", "td"}:
            self._in_snip = False
            snip = _strip_html("".join(self._snip))
            if snip and self.results and not self.results[-1].get("snippet"):
                self.results[-1]["snippet"] = snip

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title.append(data)
        elif self._in_snip:
            self._snip.append(data)


class _BingParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.results: list[dict[str, str]] = []
        self._in_algo = 0
        self._in_h2_a = False
        self._in_caption = False
        self._href = ""
        self._title: list[str] = []
        self._snip: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        d = {k: (v or "") for k, v in attrs}
        cls = d.get("class") or ""
        classes = cls.split()
        if tag == "li" and "b_algo" in classes:
            self._in_algo += 1
            self._href = ""
            self._title = []
            self._snip = []
        if self._in_algo and tag == "a" and not self._href:
            href = d.get("href") or ""
            if href.startswith("http"):
                self._href = href
                self._in_h2_a = True
                self._title = []
        if self._in_algo and (tag == "p" or "b_lineclamp" in classes or "b_caption" in classes):
            if not self._in_caption:
                self._in_caption = True

    def handle_endtag(self, tag: str) -> None:
        if self._in_h2_a and tag == "a":
            self._in_h2_a = False
        if self._in_caption and tag in {"p", "div"}:
            self._in_caption = False
        if tag == "li" and self._in_algo:
            title = _strip_html("".join(self._title))
            url = unwrap_url(self._href)
            snip = _strip_html("".join(self._snip))
            if url and title:
                self.results.append({"title": title, "url": url, "snippet": snip})
            self._in_algo = max(0, self._in_algo - 1)
            self._href = ""
            self._title = []
            self._snip = []

    def handle_data(self, data: str) -> None:
        if not self._in_algo:
            return
        if self._in_h2_a:
            self._title.append(data)
        elif self._in_caption:
            self._snip.append(data)


def parse_ddg_html(body: str) -> list[dict[str, Any]]:
    p = _DDGParser()
    try:
        p.feed(body or "")
        p.close()
    except Exception:
        pass
    return p.results


def parse_bing_html(body: str) -> list[dict[str, Any]]:
    p = _BingParser()
    try:
        p.feed(body or "")
        p.close()
    except Exception:
        pass
    if p.results:
        return p.results
    # Fallback: first http(s) links in b_algo blocks via regex.
    out: list[dict[str, str]] = []
    for m in re.finditer(
        r'class="b_algo".{0,800}?href="(https?://[^"]+)"[^>]*>(.*?)</a>',
        body or "",
        re.I | re.S,
    ):
        out.append({"title": _strip_html(m.group(2)), "url": m.group(1), "snippet": ""})
    return out


def _ddgs_class():
    try:
        from ddgs import DDGS  # type: ignore

        return DDGS
    except Exception:
        pass
    try:
        from duckduckgo_search import DDGS  # type: ignore

        return DDGS
    except Exception:
        return None


def _fetch(url: str, *, data: bytes | None = None, timeout: float = 14) -> str:
    req = urllib.request.Request(
        url,
        data=data,
        method="POST" if data is not None else "GET",
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise ExampleError(f"http {e.code} from {urlparse(url).netloc}") from e
    except urllib.error.URLError as e:
        raise ExampleError(f"network error contacting {urlparse(url).netloc}: {e.reason}") from e
    charset = "utf-8"
    try:
        charset = resp.headers.get_content_charset() or "utf-8"  # type: ignore[name-defined]
    except Exception:
        pass
    return raw.decode(charset, "replace")


def _search_ddgs(query: str, limit: int) -> list[dict[str, Any]] | None:
    cls = _ddgs_class()
    if cls is None:
        return None
    rows: list[dict[str, Any]] = []
    client = cls()
    try:
        text = getattr(client, "text", None)
        if text is None:
            return None
        found = text(query, max_results=max(int(limit or 8), 1))
        for item in found or []:
            if isinstance(item, dict):
                rows.append(item)
    finally:
        close = getattr(client, "close", None)
        if callable(close):
            try:
                close()
            except Exception:
                pass
    return rows


def _search_ddg_html(query: str, limit: int) -> list[dict[str, Any]]:
    data = urllib.parse.urlencode({"q": query}).encode("utf-8")
    body = _fetch(DDG_HTML, data=data)
    return parse_ddg_html(body)[: max(int(limit or 8) * 3, 8)]


def _search_bing_html(query: str, limit: int) -> list[dict[str, Any]]:
    url = BING_HTML + "?" + urllib.parse.urlencode({"q": query, "setlang": "en"})
    body = _fetch(url)
    return parse_bing_html(body)[: max(int(limit or 8) * 3, 8)]


def _github_json(url: str) -> Any:
    req = urllib.request.Request(
        url,
        method="GET",
        headers={
            "User-Agent": GITHUB_UA,
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise ExampleError(f"http {e.code} from api.github.com") from e
    except urllib.error.URLError as e:
        raise ExampleError(f"network error contacting api.github.com: {e.reason}") from e
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception as e:
        raise ExampleError("github: invalid json") from e


def _search_github_repos(query: str, per_page: int = 8) -> list[dict[str, Any]]:
    q = str(query or "").strip()
    if not q:
        return []
    url = GITHUB_SEARCH + "?" + urllib.parse.urlencode(
        {"q": q, "sort": "stars", "per_page": str(max(1, min(int(per_page or 8), 10)))}
    )
    data = _github_json(url)
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return []
    rows: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        html = str(it.get("html_url") or "").strip()
        full = str(it.get("full_name") or "").strip()
        if not html:
            continue
        try:
            stars = int(it.get("stargazers_count") or 0)
        except (TypeError, ValueError):
            stars = 0
        rows.append(
            {
                "title": full or str(it.get("name") or html),
                "url": html,
                "snippet": str(it.get("description") or ""),
                "kind": "repo",
                "stars": stars,
            }
        )
    return rows


def _web_search_query(query: str, limit: int) -> list[dict[str, Any]]:
    """One live-web query through ddgs → DDG HTML → Bing. Never invents rows."""
    cap = max(1, int(limit or 8))
    try:
        ddgs_rows = _search_ddgs(query, cap)
    except Exception:
        ddgs_rows = None
    if ddgs_rows:
        return list(ddgs_rows)
    try:
        html_rows = _search_ddg_html(query, cap)
        if html_rows:
            return list(html_rows)
    except Exception:
        pass
    try:
        bing_rows = _search_bing_html(query, cap)
        if bing_rows:
            return list(bing_rows)
    except Exception:
        pass
    return []


def _canonical_url(url: str) -> str:
    raw = unwrap_url(url)
    repo = github_repo_key(raw)
    if repo:
        return f"https://github.com/{repo}"
    parsed = urlparse(raw)
    host = (parsed.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = (parsed.path or "").rstrip("/")
    return f"https://{host}{path}"


def _row_stars(raw: dict[str, Any]) -> int:
    try:
        return int(raw.get("stars") or raw.get("stargazers_count") or 0)
    except (TypeError, ValueError):
        return 0


def _select_results(rows: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    """Filter listicles, prefer real repos/products, dedup, score-sort."""
    cap = max(1, int(limit or 8))
    prepared: list[dict[str, Any]] = []
    seen_url: set[str] = set()
    seen_repo: set[str] = set()
    for raw in rows:
        if not isinstance(raw, dict):
            continue
        url = unwrap_url(str(raw.get("url") or raw.get("href") or raw.get("link") or ""))
        if not url or is_junk(url):
            continue
        title = str(raw.get("title") or "")
        snippet = str(raw.get("snippet") or raw.get("body") or "")
        if is_listicle(url, title, snippet):
            continue
        canon = _canonical_url(url)
        if canon in seen_url:
            continue
        repo = github_repo_key(url)
        if repo:
            if repo in seen_repo:
                continue
            url = f"https://github.com/{repo}"
            canon = url
        kind = str(raw.get("kind") or "") or guess_kind(url, title=title)
        if repo:
            kind = "repo"
        row = example_from_url(url, title=title, snippet=snippet, kind=kind)
        stars = _row_stars(raw)
        if stars:
            row["stars"] = stars
        row["_docs"] = looks_like_docs(url, row.get("host") or "")
        seen_url.add(canon)
        if repo:
            seen_repo.add(repo)
        prepared.append(row)

    def rank_key(r: dict[str, Any]) -> tuple:
        kind = r.get("kind") or "page"
        stars = -int(r.get("stars") or 0)
        if kind == "repo" or github_repo_key(str(r.get("url") or "")):
            return (0, stars, 0)
        if kind == "product":
            return (1, 0, 0)
        if kind == "paper":
            return (2, 0, 0)
        if r.get("_docs"):
            return (3, 0, 0)
        return (4, 0, 0)

    prepared.sort(key=rank_key)
    repos = [r for r in prepared if r.get("kind") == "repo"]
    products = [r for r in prepared if r.get("kind") == "product"]
    papers = [r for r in prepared if r.get("kind") == "paper"]
    docs = [r for r in prepared if r.get("_docs") and r.get("kind") == "page"]
    essays = [
        r
        for r in prepared
        if r.get("kind") == "page" and not r.get("_docs")
    ]
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    # Repos first, then products, papers, docs, and at most one essay.
    buckets = (repos, products, papers, docs, essays[:1])
    for bucket in buckets:
        for r in bucket:
            key = _canonical_url(str(r.get("url") or ""))
            if not key or key in seen:
                continue
            seen.add(key)
            r.pop("_docs", None)
            out.append(r)
            if len(out) >= cap:
                return out
    return out


def search(query: str, limit: int = 8) -> list[dict[str, Any]]:
    """In-depth search: distill intents, GitHub first, then web. Never invents rows."""
    q = str(query or "").strip()
    if not q:
        return []
    cap = max(1, min(int(limit or 8), 20))
    intents = distill_intents(q)
    if not intents:
        intents = [q]
    collected: list[dict[str, Any]] = []
    errors: list[str] = []

    for intent in intents:
        try:
            collected.extend(_search_github_repos(intent, per_page=8))
        except Exception as e:
            errors.append(f"github:{intent}: {e}")

    for intent in intents:
        try:
            collected.extend(_web_search_query(f"site:github.com {intent}", cap))
        except Exception as e:
            errors.append(f"web-gh:{intent}: {e}")

    for intent in intents:
        product_q = f'{intent} official product -best -"top 10" -alternatives'
        try:
            collected.extend(_web_search_query(product_q, cap))
        except Exception as e:
            errors.append(f"web-product:{intent}: {e}")

    out = _select_results(collected, cap)
    if out:
        return out
    if collected:
        return []
    if errors:
        raise ExampleError("search failed: " + "; ".join(errors))
    return []

def with_examples(task: str, selected: Any) -> str:
    """Append the quality-examples block when a comparison set exists."""
    block = format_prompt_block(selected)
    if not block:
        return task
    return task.rstrip() + "\n\n" + block + "\n"

