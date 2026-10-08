"""Interview for a new review bar.

A bar is only worth having if it encodes what a person actually means by good,
and nobody writes that down accurately by filling in a JSON schema. Handed a
template, you get a bar that reads like a template. Asked to name something you
can point at, you get an anchor — and anchors are the whole reason a 5 still
means the same thing next month.

So this asks. What kind of work, who builds against it, who holds it, what does
great look like, what does failure look like, which dimensions matter, what
passes, where does the file live. Then it writes the bar, and the existing
job-attach path picks it up with no further ceremony.

Two rules are enforced rather than suggested:

* **Nobody grades their own work.** A seat cannot appear on both sides.
* **At least one reference.** A scale with no anchor is an opinion with numbers
  on it, which is the failure mode the bar exists to prevent.

The asking is injected (`ask`) so the flow can be driven by a test as easily as
by a person, and so a non-interactive shell fails loudly instead of writing a
half-answered bar.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path
from typing import Any, Callable

Ask = Callable[..., str]

#: Starting points per kind of work. These are proposals to edit, not a menu —
#: the question is "which dimensions matter", and having something on the table
#: gets a better answer than a blank prompt does.
KIND_DIMENSIONS: dict[str, list[dict[str, str]]] = {
    "code": [
        {"id": "root_cause", "name": "Root cause, not symptom"},
        {"id": "evidence", "name": "Evidence a stranger could re-run"},
        {"id": "scope", "name": "Only what was asked"},
        {"id": "failure_handling", "name": "Behaviour when things go wrong"},
        {"id": "legibility", "name": "Reads like the code around it"},
    ],
    "design": [
        {"id": "hierarchy", "name": "Hierarchy — the eye lands in the right place"},
        {"id": "coherence", "name": "Coherence with what already exists"},
        {"id": "sourcing", "name": "Guideline sourcing"},
        {"id": "efficiency", "name": "Efficiency — steps and cost to the user"},
        {"id": "accessibility", "name": "Contrast and reach"},
    ],
    "writing": [
        {"id": "claim", "name": "Says one thing, and says it first"},
        {"id": "evidence", "name": "Every claim carries its support"},
        {"id": "voice", "name": "Sounds like a person, not a template"},
        {"id": "length", "name": "Earns every paragraph"},
        {"id": "accuracy", "name": "Nothing asserted that was not checked"},
    ],
    "research": [
        {"id": "sourcing", "name": "Primary sources, named and dated"},
        {"id": "coverage", "name": "Looked where the answer would actually be"},
        {"id": "contradiction", "name": "Reports what disagrees with the thesis"},
        {"id": "confidence", "name": "Separates established from inferred"},
        {"id": "usefulness", "name": "Answers the question that was asked"},
    ],
}
_GENERIC = [
    {"id": "correctness", "name": "Does what was asked"},
    {"id": "evidence", "name": "Shows its work"},
    {"id": "scope", "name": "Only what was asked"},
    {"id": "craft", "name": "Fits what is already there"},
]

DEFAULT_MIN_EACH = 3
DEFAULT_MIN_MEAN = 4.0


def proposed_dimensions(kind: str) -> list[dict[str, str]]:
    """What to put on the table for a given kind of work.

    A shipped bar of the same kind wins, because its wording of what a 5 and a 1
    look like is already the most careful statement of those dimensions we have,
    and asking someone to retype it from memory produces a worse bar. Only the
    dimensions a person invents themselves need describing from scratch.
    """
    try:
        from .review_bar import load_bars

        packaged = load_bars(None).get(kind)
        if packaged and packaged.get("dimensions"):
            return [dict(d) for d in packaged["dimensions"]]
    except Exception:
        pass
    return [dict(d) for d in KIND_DIMENSIONS.get(kind, _GENERIC)]


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", str(text).strip().lower()).strip("-")
    return s or "bar"


def _split(text: str) -> list[str]:
    return [p.strip() for p in re.split(r"[,\n]+", text or "") if p.strip()]


# ——— roster helpers ————————————————————————————————————————————————

def seats_by_label(state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    from .state import workers_from_state

    return {str(w.get("label") or ""): w for w in workers_from_state(state)}


def resolve_seats(state: dict[str, Any], answer: str) -> list[str]:
    """Turn what a person typed into seat ids.

    Accepts seat ids ("w16"), full labels ("Migrator — Website"), or the shorthand a
    person actually uses for a group ("CyberPong", "Website", "Design"), which
    expands to that lead and the coders under it.
    """
    from .state import workers_from_state

    workers = list(workers_from_state(state))
    by_id = {str(w.get("id")): w for w in workers}
    out: list[str] = []

    def add(seat_id: str) -> None:
        if seat_id and seat_id not in out:
            out.append(seat_id)

    for token in _split(answer):
        low = token.lower()
        if token in by_id:
            add(token)
            continue
        exact = [w for w in workers if str(w.get("label") or "").lower() == low]
        if exact:
            add(str(exact[0].get("id")))
            continue
        # Group shorthand: every seat whose label mentions it, leads and coders
        # only — a reviewer is not a builder.
        hits = [w for w in workers if low in str(w.get("label") or "").lower()]
        for w in hits:
            role = str(w.get("mission_role") or w.get("role") or "")
            if role == "coder":
                add(str(w.get("id")))
    return out


def lead_groups(state: dict[str, Any]) -> list[dict[str, Any]]:
    """The main agents and the groups behind them, for a picker.

    A person thinks "give this to Growth", not "w5, w6, w7, w8" — so the choice
    offered is the lead, and the seats come from the roster.
    """
    from .state import workers_from_state

    workers = list(workers_from_state(state))
    out: list[dict[str, Any]] = []
    for w in workers:
        if str(w.get("parent_id") or ""):
            continue
        lead = str(w.get("id") or "")
        seats = group_seats(state, lead)
        out.append({
            "lead": lead,
            "label": str(w.get("label") or lead),
            "seats": seats,
            # Who would hold it, decided by the same rule the writer uses, so a
            # picker can say "this lane has nobody to hold it" BEFORE someone
            # fills in a whole bar and gets refused at the end.
            "held_by": suggest_reviewers(state, "code", seats),
        })
    return out


def group_seats(state: dict[str, Any], lead_id: str) -> list[str]:
    """Everyone in a group who could be measured: the lead and its reports.

    Reviewers are left out, and that is the rule rather than a nicety — a seat
    that holds the bar cannot also be graded by it. Note this is NOT the same as
    the coder filter used for free-text group shorthand: Growth's writers and
    Ops' operators are not coders, so filtering on that role gave those four
    groups a bar covering their lead alone.
    """
    from .state import workers_from_state

    out: list[str] = []
    for w in workers_from_state(state):
        wid = str(w.get("id") or "")
        role = str(w.get("mission_role") or w.get("role") or "")
        if role == "reviewer":
            continue
        if wid == lead_id or str(w.get("parent_id") or "") == lead_id:
            out.append(wid)
    return out


def suggest_reviewers(state: dict[str, Any], kind: str, builders: list[str]) -> list[str]:
    """Who should hold this bar, if the person has no one in mind.

    Code goes to a Grok reviewer — cheap, and not the same runtime as the seat
    it is grading. Design goes to the reviewer in the Design lane. Anything else
    falls back to a reviewer in the builders' own lane, which is at least
    somebody who sees the work.
    """
    from .state import workers_from_state

    workers = list(workers_from_state(state))
    reviewers = [
        w for w in workers
        if str(w.get("mission_role") or w.get("role") or "") == "reviewer"
        and str(w.get("id")) not in builders
    ]
    if not reviewers:
        return []
    if kind == "design":
        design = [w for w in reviewers if "design" in str(w.get("label") or "").lower()]
        if design:
            return [str(design[0].get("id"))]
    if kind == "code":
        grok = [w for w in reviewers if str(w.get("type") or "").lower() == "grok"]
        if grok:
            return [str(grok[0].get("id"))]
    # Same lane only. Falling back to "any reviewer" put Delivery's, Growth's
    # and Research's bar in the hands of Engineering's reviewer — which is a
    # lane crossing the team rules forbid, and it happened silently. When a
    # group has no reviewer of its own, say nothing and let a person decide.
    parents = {str((next((x for x in workers if str(x.get("id")) == b), {}) or {}).get("parent_id") or b)
               for b in builders}
    lane = [w for w in reviewers if str(w.get("parent_id") or "") in parents]
    return [str(lane[0].get("id"))] if lane else []


# ——— building the bar ————————————————————————————————————————————————

def build_bar(
    *,
    bar_id: str,
    title: str,
    kind: str,
    summary: str,
    builders: list[str],
    reviewers: list[str],
    dimensions: list[dict[str, str]],
    references: list[dict[str, Any]],
    min_each: int = DEFAULT_MIN_EACH,
    min_mean: float = DEFAULT_MIN_MEAN,
    never_waived: str = "",
) -> dict[str, Any]:
    """Assemble a bar in the shape review_bar.load_bars expects.

    Raises if a seat would grade itself, or if there is no reference to anchor
    against — both are conditions that make the resulting bar worse than none.
    """
    overlap = sorted(set(builders) & set(reviewers))
    if overlap:
        raise ValueError(
            f"{', '.join(overlap)} would be both builder and reviewer — "
            "nobody grades their own work"
        )
    if not references:
        raise ValueError(
            "a bar needs at least one reference: a scale with nothing to point "
            "at is an opinion with numbers on it"
        )
    note = "One dimension below %d fails the whole claim regardless of the mean." % min_each
    if never_waived.strip():
        note += f" {never_waived.strip()}"
    return {
        "id": bar_id,
        "title": title,
        "version": 1,
        "summary": summary,
        "scale": {
            "min": 1,
            "max": 5,
            "labels": {
                "1": "Does not clear the bar.",
                "2": "Something real is there, but a reviewer has to redo the work.",
                "3": "Works, and is honestly reported. Thin somewhere.",
                "4": "Solid. Would ship without rework.",
                "5": "Anchor quality — as good as the reference.",
            },
        },
        "pass": {"min_each": min_each, "min_mean": min_mean, "note": note},
        "scope": {
            "reviewer_seats": reviewers,
            "reviewer_roles": [],
            "seats": builders,
            "mission_roles": [],
        },
        "dimensions": [
            {
                "id": d.get("id") or slug(d.get("name", "")),
                "name": d.get("name", ""),
                "weight": 1.0,
                "five": d.get("five") or "",
                "one": d.get("one") or "",
            }
            for d in dimensions
        ],
        "references": references,
    }


def bar_dir(scope: str, project_root: str | None) -> Path:
    """Where the file lands. Mirrors review_bar's own lookup order."""
    if scope == "project":
        pr = (project_root or "").strip()
        if not pr:
            raise ValueError("no project_root on this team — pick machine scope")
        return Path(pr).expanduser() / ".pong" / "review"
    return Path(os.path.expanduser("~/.pong/review"))


def write_bar(bar: dict[str, Any], scope: str, project_root: str | None,
              inherit_from: str | None = None) -> dict[str, Any]:
    """Write the bar and a references folder, and stub any file it names.

    The stubs matter: a reference the reviewer cannot open is the same as no
    reference, and an empty file with a heading is an obvious invitation to
    finish the job.
    """
    root = bar_dir(scope, project_root)
    bars = root / "bars"
    refs = root / "references"
    bars.mkdir(parents=True, exist_ok=True)
    refs.mkdir(parents=True, exist_ok=True)
    path = bars / f"{bar['id']}.json"
    path.write_text(json.dumps(bar, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # An override lands in a different directory from the bar it overrides, and
    # `reference_paths` resolves every reference relative to whichever directory
    # the bar was loaded from. So without this, editing the shipped code bar
    # would point it at three FRESH STUBS and the already-scored anchors the
    # whole bar rests on would be gone — replaced by an empty template, silently.
    # Carry the real files across first; only genuinely new references get a stub.
    source = Path(inherit_from).expanduser() / "references" if inherit_from else None

    made: list[str] = []
    copied: list[str] = []
    for ref in bar.get("references") or []:
        name = str(ref.get("file") or "").strip()
        if not name:
            continue
        rp = refs / name
        if rp.exists():
            continue
        if source is not None and (source / name).is_file():
            shutil.copyfile(source / name, rp)
            copied.append(str(rp))
            continue
        rp.write_text(
            f"# Reference · {bar['id']} · score {ref.get('score')}\n\n"
            f"{ref.get('why') or ''}\n\n"
            "## What this is\n\n"
            "Paste or describe the actual work here — the diff, the screen, the\n"
            "page. A reviewer has to be able to compare against it.\n\n"
            "## Why it scores what it scores\n\n"
            "One line per dimension.\n",
            encoding="utf-8",
        )
        made.append(str(rp))
    return {"bar_path": str(path), "references_dir": str(refs),
            "stubs": made, "carried": copied}


# ——— the interview ————————————————————————————————————————————————

def interview(ask: Ask, state: dict[str, Any]) -> dict[str, Any]:
    """Ask the questions a critic needs, in order, and return the answers."""
    kind_raw = ask(
        "1. What kind of work is this bar for?\n"
        "   code / design / writing / research — or your own words",
        default="code",
    )
    kind = slug(kind_raw)
    known = kind if kind in KIND_DIMENSIONS else "custom"

    title = ask("2a. Give the bar a title", default=f"{kind_raw.strip().title()} work")
    bar_id = slug(ask("2b. Short id for the file", default=slug(title)))
    summary = ask("2c. One line: what does this bar cover?", default=f"The bar for {kind_raw.strip()}.")

    builders_raw = ask(
        "3. Who builds against it?\n"
        "   seat ids (w16, w18), full labels, or a group (CyberPong / Website / Design)"
    )
    builders = resolve_seats(state, builders_raw)
    if not builders:
        raise ValueError(f"no seats matched {builders_raw!r} — nothing would carry this bar")

    suggested = suggest_reviewers(state, known, builders)
    rev_raw = ask(
        "4. Who holds the bar? (never the builder)"
        + (f"\n   suggested: {', '.join(suggested)}" if suggested else ""),
        default=", ".join(suggested),
    )
    reviewers = resolve_seats(state, rev_raw) or _split(rev_raw)
    # A reviewer is not a coder, so resolve_seats' coder filter will miss it;
    # fall back to treating the answer as ids/labels directly.
    reviewers = [r for r in reviewers if r]
    if not reviewers:
        raise ValueError("a bar with nobody holding it never gets applied")

    refs: list[dict[str, Any]] = []
    great = ask(
        "5. What does GREAT look like? Name something real you can point at —\n"
        "   a file, a URL, a shipped screen, a paper. At least one.\n"
        "   (if you have none, say 'help' and we note it as an open task)"
    )
    if great.strip().lower() in ("help", "none", ""):
        refs.append({
            "file": f"{bar_id}-5-TODO-find-an-anchor.md",
            "score": 5,
            "why": "OPEN: no anchor yet. Find one before this bar is trusted — "
                   "without it a 5 means whatever the reviewer felt that day.",
        })
    else:
        for i, item in enumerate(_split(great), 1):
            refs.append({
                "file": f"{bar_id}-5-{slug(item)[:40] or f'anchor-{i}'}.md",
                "score": 5,
                "why": item,
            })

    bad = ask("6. What does FAIL look like? (optional — a 1 keeps the floor honest)", default="")
    for item in _split(bad):
        refs.append({"file": f"{bar_id}-1-{slug(item)[:40]}.md", "score": 1, "why": item})

    proposed = proposed_dimensions(known)
    dims_raw = ask(
        "7. Which dimensions matter?\n"
        "   proposed: " + ", ".join(d["name"] for d in proposed) + "\n"
        "   press return to take these, or list your own",
        default="",
    )
    if dims_raw.strip():
        dimensions = [{"id": slug(n), "name": n} for n in _split(dims_raw)]
    else:
        dimensions = [dict(d) for d in proposed]
    # Only the ones invented here need describing. Taking the proposed set keeps
    # the interview a fixed length instead of adding two prompts per dimension,
    # which is where a person gives up and accepts whatever is offered.
    for d in dimensions:
        if not d.get("five"):
            d["five"] = ask(f"   5 on '{d['name']}' looks like", default="")
        if not d.get("one"):
            d["one"] = ask(f"   1 on '{d['name']}' looks like", default="")

    min_each = int(ask("8a. Minimum on every dimension", default=str(DEFAULT_MIN_EACH)) or DEFAULT_MIN_EACH)
    min_mean = float(ask("8b. Minimum mean", default=str(DEFAULT_MIN_MEAN)) or DEFAULT_MIN_MEAN)
    never = ask("8c. Anything never waived? (Design treats contrast this way)", default="")

    scope = (ask(
        "9. Where does this bar live?\n"
        "   project = this repo only · machine = everywhere on this Mac",
        default="project",
    ) or "project").strip().lower()
    if scope not in ("project", "machine"):
        scope = "project"

    return {
        "bar_id": bar_id, "title": title, "kind": known, "summary": summary,
        "builders": builders, "reviewers": reviewers, "dimensions": dimensions,
        "references": refs, "min_each": min_each, "min_mean": min_mean,
        "never_waived": never, "scope": scope,
    }


def run_answers(answers: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    """Build and write a bar from already-collected answers.

    The interview above is one way to gather them; a form in CyberPong is
    another. Both land here, so the GUI is a way of asking the questions rather
    than a second implementation of what a bar is — and the same refusals apply
    whichever asked.
    """
    kind = slug(str(answers.get("kind") or "code"))
    known = kind if kind in KIND_DIMENSIONS else "custom"
    # Groups are the picker's language; free text stays supported for the CLI.
    builders: list[str] = []
    for lead in answers.get("groups") or []:
        for seat in group_seats(state, str(lead)):
            if seat not in builders:
                builders.append(seat)
    if not builders:
        builders = resolve_seats(state, str(answers.get("builders") or ""))
    if not builders:
        raise ValueError(
            f"no seats matched {answers.get('builders')!r} — nothing would carry this bar"
        )
    reviewers = resolve_seats(state, str(answers.get("reviewers") or "")) \
        or _split(str(answers.get("reviewers") or "")) \
        or suggest_reviewers(state, known, builders)
    if not reviewers:
        raise ValueError("a bar with nobody holding it never gets applied")

    # Already-built dimensions pass straight through.
    #
    # The comma-separated form below cannot carry an existing bar back in: it
    # keeps only names, so every "5 looks like" / "1 looks like" anchor comes
    # back empty, and a name that contains a comma is torn in two — the shipped
    # code bar's "Root cause, not symptom" round-trips as five dimensions
    # becoming six. Editing a live bar has to hand the dimensions over intact,
    # so a list of dicts is taken as final. The string form still works for
    # everyone who is naming fresh dimensions.
    dims_given = answers.get("dimensions")
    if isinstance(dims_given, list) and dims_given:
        dimensions = [dict(d) for d in dims_given if isinstance(d, dict)]
        if not dimensions:
            raise ValueError("dimensions were given as a list but none were readable")
    elif str(dims_given or "").strip():
        dimensions = [{"id": slug(n), "name": n, "five": "", "one": ""}
                      for n in _split(str(dims_given))]
    else:
        dimensions = proposed_dimensions(known)

    refs: list[dict[str, Any]] = []
    bar_id = slug(str(answers.get("bar_id") or answers.get("title") or kind))
    # Same reasoning for references. Their `file` is the name of a markdown file
    # that actually exists on disk, and deriving it again from the prose in
    # `why` renames it — "code-5-island-crash.md" would come back as
    # "code-5-disproved-the-briefed-root-cause-with-a-.md", leaving the real
    # anchor orphaned and the bar pointing at an empty stub.
    refs_given = answers.get("references")
    if isinstance(refs_given, list) and refs_given:
        refs = [dict(r) for r in refs_given if isinstance(r, dict) and r.get("file")]
        if not refs:
            raise ValueError("references were given as a list but none named a file")
    # Anything newly added still gets its file name derived here, so the app
    # never has to have an opinion about what a reference file is called.
    great = str(answers.get("great") or "").strip()
    if great and great.lower() not in ("help", "none"):
        for i, item in enumerate(_split(great), 1):
            refs.append({"file": f"{bar_id}-5-{slug(item)[:40] or f'anchor-{i}'}.md",
                         "score": 5, "why": item})
    elif not refs:
        refs.append({
            "file": f"{bar_id}-5-TODO-find-an-anchor.md", "score": 5,
            "why": "OPEN: no anchor yet. Find one before this bar is trusted — "
                   "without it a 5 means whatever the reviewer felt that day.",
        })
    for item in _split(str(answers.get("fail") or "")):
        refs.append({"file": f"{bar_id}-1-{slug(item)[:40]}.md", "score": 1, "why": item})

    bar = build_bar(
        bar_id=bar_id,
        title=str(answers.get("title") or bar_id),
        kind=known,
        summary=str(answers.get("summary") or ""),
        builders=builders,
        reviewers=reviewers,
        dimensions=dimensions,
        references=refs,
        min_each=int(answers.get("min_each") or DEFAULT_MIN_EACH),
        min_mean=float(answers.get("min_mean") or DEFAULT_MIN_MEAN),
        never_waived=str(answers.get("never_waived") or ""),
    )
    scope = str(answers.get("scope") or "project").strip().lower()
    if scope not in ("project", "machine"):
        scope = "project"
    written = write_bar(bar, scope, str(state.get("project_root") or ""),
                        inherit_from=str(answers.get("inherit_refs_from") or "") or None)
    return {"bar": bar, **written, "scope": scope}


def run_init(ask: Ask, state: dict[str, Any]) -> dict[str, Any]:
    """Interview, build, write. Returns everything the caller should print."""
    a = interview(ask, state)
    bar = build_bar(
        bar_id=a["bar_id"], title=a["title"], kind=a["kind"], summary=a["summary"],
        builders=a["builders"], reviewers=a["reviewers"], dimensions=a["dimensions"],
        references=a["references"], min_each=a["min_each"], min_mean=a["min_mean"],
        never_waived=a["never_waived"],
    )
    written = write_bar(bar, a["scope"], str(state.get("project_root") or ""))
    return {"bar": bar, **written, "scope": a["scope"]}
