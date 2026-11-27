#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build or check the v0 result fixtures under testdata/fixtures/v0.

Usage: fixtures-v0.py build | check

The fixtures describe campaigns over the synthetic project in
examples/toyparse. This script writes the plans and bundles only. Each case's
expected.json is written by hand and is never generated here.

Digests use RFC 8785 (JCS) over the subset these fixtures need: objects,
arrays, strings, integers within +/-(2^53 - 1), booleans and null. Floats,
larger integers and non-ASCII keys are refused, so the simple encoding below
is exact for that subset. It is an independent oracle for the fixtures and
shares no code with fuzzmuster.

`check` rebuilds everything in a temporary directory and fails if any
committed fixture file differs or is missing, or if an extra file is present
(expected.json files excepted).
"""

import copy
import filecmp
import hashlib
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "examples", "toyparse")
OUT = os.path.join(ROOT, "testdata", "fixtures", "v0")

REVISION = "0123456789abcdef0123456789abcdef01234567"
TOOL = "fuzzmuster 0.0.0-fixture"  # never a released version
TARGETS = ["parse_record", "parse_stream", "render_record"]


# ---------------------------------------------------------------- encoding


MAX_SAFE = 2**53 - 1


def _check(value):
    if isinstance(value, float):
        raise ValueError("floats are outside the fixture JCS subset")
    if isinstance(value, int) and not isinstance(value, bool):
        # RFC 8785 serialises numbers as IEEE 754 binary64; beyond this range
        # a conforming encoder would print a different value.
        if not -MAX_SAFE <= value <= MAX_SAFE:
            raise ValueError("integers must be within +/-(2^53 - 1)")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not key.isascii():
                raise ValueError("keys must be ASCII strings")
            _check(item)
    elif isinstance(value, list):
        for item in value:
            _check(item)


def jcs(value):
    _check(value)
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def doc_digest(value):
    return "sha256:" + hashlib.sha256(jcs(value)).hexdigest()


def byte_digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def hexof(digest):
    return digest.split(":", 1)[1]


def body_ref(data, media_type):
    return {"digest": byte_digest(data), "length": len(data), "media_type": media_type}


# Encrypted bodies are stand-ins: fixed bytes labelled as ciphertext, never a
# real encryption and never a real input. The reference binds those bytes, as
# it binds the ciphertext of a real body, and names a key without holding it.
ENCRYPTION = {"scheme": "fixture", "key_ref": "fixture-key"}


def sealed(label):
    data = ("fixture ciphertext stand-in: " + label).encode()
    ref = body_ref(data, "application/octet-stream")
    ref["encryption"] = dict(ENCRYPTION)
    return data, ref


def pretty(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


# ---------------------------------------------------------------- plan


def seed_manifest(rel_dir):
    base = os.path.join(PROJECT, rel_dir)
    entries = []
    for name in sorted(os.listdir(base)):
        path = os.path.join(base, name)
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as handle:
                data = handle.read()
            entries.append(
                {"path": name, "digest": byte_digest(data), "length": len(data)}
            )
    entries.sort(key=lambda entry: entry["path"])
    return {"v": 0, "entries": entries}


def make_plan(per_job="PT1H", total="PT3H"):
    with open(os.path.join(PROJECT, "fuzzmuster.yaml"), "rb") as handle:
        project_bytes = handle.read()
    manifests = {t: seed_manifest("fuzz/seeds/" + t) for t in TARGETS}
    jobs = [
        {
            "job_id": t,
            "target": t,
            "entry": t,
            "required": True,
            "budget": per_job,
            "seeds": {
                "manifest_digest": doc_digest(manifests[t]),
                "count": len(manifests[t]["entries"]),
            },
        }
        for t in TARGETS
    ]
    plan = {
        "v": 0,
        "kind": "fuzzmuster.plan",
        "project": {"name": "toyparse", "file_digest": byte_digest(project_bytes)},
        "source": {"vcs": "git", "revision": REVISION},
        "profile": {"name": "linux-mutate", "mode": "mutate"},
        "platform": {"os": "linux", "arch": "amd64"},
        "toolchain": {
            "adapter": "cargo-fuzz",
            "adapter_version": "0.12.0",
            "engine": "libfuzzer",
            "toolchain": "nightly-2026-11-01",
            "sanitizer": "address",
        },
        "required_controls": [
            {"control": "engine_input_timeout", "duration": "PT10S"},
            {"control": "engine_rss_limit", "mebibytes": 1024},
            {"control": "outputs_outside_worktree"},
        ],
        "budget": {"per_job": per_job, "total": total},
        "jobs": jobs,
    }
    return plan, manifests


# ---------------------------------------------------------------- identities


def task_id(plan_digest, job_id):
    return doc_digest(
        {
            "authority": "fuzzmuster-plan-" + hexof(plan_digest),
            "invocation_key": job_id,
            "v": 0,
        }
    )


def attempt_id(tid, n):
    return doc_digest({"attempt_n": n, "task_id": tid, "v": 0})


# ---------------------------------------------------------------- records


def instant(minute):
    hour, minute = divmod(minute, 60)
    return "2026-11-26T%02d:%02d:00.000000Z" % (10 + hour, minute)


def envelope(
    stream, record_id, payload_contract, payload, actor, at, revision=1, supersedes=None
):
    record = {
        "v": 1,
        "stream": stream,
        "record_id": record_id,
        "revision": revision,
        "payload_contract": payload_contract,
        "payload": payload,
        "provenance": {"actor_kind": "process", "actor": actor, "tool": TOOL},
        "produced_at": {"instant": at, "source": "producer_clock"},
        "classification": {"retention": "standard", "sensitivity": "1-confidential"},
    }
    if supersedes is not None:
        record["supersedes"] = supersedes
    return record


def pin_of(record):
    return {
        "stream": record["stream"],
        "record_id": record["record_id"],
        "revision": record["revision"],
        "digest": doc_digest(record),
    }


LIMITS = [
    {"control": "engine_input_timeout", "duration": "PT10S", "enforced_by": "engine"},
    {"control": "engine_rss_limit", "mebibytes": 1024, "enforced_by": "engine"},
    {"control": "outputs_outside_worktree", "enforced_by": "supervisor"},
]

COVERAGE = {
    "parse_record": (18_400_000, [412, 431, 437]),
    "parse_stream": (11_900_000, [508, 529, 533]),
    "render_record": (9_700_000, [603, 618, 622]),
}


def attempt_record(
    plan,
    plan_digest,
    job_id,
    n=1,
    result="succeeded",
    outcome="budget_reached",
    used="PT1H",
    findings=(),
    start=0,
    log=None,
    limits=None,
    planned=None,
    corpus_sealed=True,
):
    tid = task_id(plan_digest, job_id)
    aid = attempt_id(tid, n)
    if planned is None:
        planned = next(j["budget"] for j in plan["jobs"] if j["job_id"] == job_id)
    execs, cov = COVERAGE[job_id]
    reached = used == planned
    if not reached:
        execs = execs // 3
        cov = cov[:1]
    label = "corpus manifest %s %d" % (job_id, n)
    if corpus_sealed:
        _, corpus = sealed(label)
    else:
        corpus = body_ref(("synthetic " + label).encode(), "application/json")
    artifacts = [{"role": "corpus_manifest", "custody": "private", "body": corpus}]
    finding_items = []
    for index, kind in enumerate(findings, start=1):
        _, ref = sealed("%s input %s %d" % (kind, job_id, index))
        finding_items.append(
            {
                "finding_id": "%s-%d" % (job_id.replace("_", "-"), index),
                "kind": kind,
                "input": ref,
                "first_seen": "PT12M30S",
            }
        )
        artifacts.append({"role": "finding_input", "custody": "private", "body": ref})
    if log is not None:
        custody, ref = log
        artifacts.append({"role": "engine_log", "custody": custody, "body": ref})
    payload = {
        "v": 0,
        "plan_digest": plan_digest,
        "job_id": job_id,
        "task_id": tid,
        "attempt_n": n,
        "attempt_id": aid,
        "result": result,
        "outcome_code": outcome,
        "budget": {"planned": planned, "used": used, "reached": reached},
        "worker_claims": {
            "platform": {"os": "linux", "arch": "amd64"},
            "subject_binary": byte_digest(("synthetic fuzz binary " + job_id).encode()),
            "toolchain": copy.deepcopy(plan["toolchain"]),
            "limits": copy.deepcopy(limits if limits is not None else LIMITS),
            "started_at": instant(start),
            "ended_at": instant(start + (60 if reached else 20)),
        },
        "observations": {
            "executions": execs,
            "coverage": [
                {"engine": "libfuzzer", "unit": "cov", "at": at, "value": value}
                for at, value in zip(["PT15M", "PT30M", "PT1H"], cov)
            ],
            "corpus": corpus,
            "findings": finding_items,
        },
        "artifacts": artifacts,
    }
    record = envelope(
        "fuzzmuster.attempt",
        "attempt-" + hexof(aid),
        "contract: fuzzmuster-attempt/v0",
        payload,
        "fuzzmuster-worker",
        instant(start + (60 if reached else 20)),
    )
    return record


def disposition(plan_digest, job_id, attempt, earlier=()):
    entry = {"job_id": job_id, "task_id": task_id(plan_digest, job_id)}
    if attempt is None:
        entry.update(
            {
                "state": "not_started",
                "reason": "unsupported_host",
                "budget_reached": False,
            }
        )
        return entry
    payload = attempt["payload"]
    entry.update(
        {
            "state": payload["result"],
            "reason": payload["outcome_code"],
            "budget_reached": payload["budget"]["reached"],
            "attempt": pin_of(attempt),
        }
    )
    if earlier:
        entry["earlier_attempts"] = [pin_of(a) for a in earlier]
    return entry


def campaign_record(
    plan_digest, jobs, at, host_check=None, revision=1, supersedes=None
):
    payload = {
        "v": 0,
        "plan_digest": plan_digest,
        "host_check": host_check or {"status": "supported"},
        "jobs": jobs,
    }
    return envelope(
        "fuzzmuster.campaign",
        "campaign-" + hexof(plan_digest),
        "contract: fuzzmuster-campaign/v0",
        payload,
        "fuzzmuster-collector",
        at,
        revision,
        supersedes,
    )


def bundle_record(plan_digest, members, at, revision=1, supersedes=None):
    pins = sorted(
        (pin_of(m) for m in members),
        key=lambda p: (p["digest"], p["stream"], p["record_id"], p["revision"]),
    )
    payload = {
        "kind": "set",
        "members": [{"pin": p} for p in pins],
        "member_count": len(pins),
        "closure_claim": "none",
    }
    return envelope(
        "fuzzmuster.bundle",
        "bundle-" + hexof(plan_digest),
        "contract: record-collection/v0",
        payload,
        "fuzzmuster-collector",
        at,
        revision,
        supersedes,
    )


# ---------------------------------------------------------------- cases


def write_bundle(case_dir, records, bundle, bodies=()):
    bdir = os.path.join(case_dir, "bundle")
    os.makedirs(os.path.join(bdir, "records"))
    with open(os.path.join(bdir, "bundle.json"), "wb") as handle:
        handle.write(pretty(bundle))
    for record in records:
        name = hexof(doc_digest(record)) + ".json"
        with open(os.path.join(bdir, "records", name), "wb") as handle:
            handle.write(pretty(record))
    if bodies:
        os.makedirs(os.path.join(bdir, "bodies"))
        for data in bodies:
            with open(
                os.path.join(bdir, "bodies", hexof(byte_digest(data))), "wb"
            ) as handle:
                handle.write(data)


def write_case(out, name, plan_file, description, records, bundle, bodies=()):
    case_dir = os.path.join(out, "cases", name)
    os.makedirs(case_dir)
    with open(os.path.join(case_dir, "case.json"), "wb") as handle:
        handle.write(
            pretty({"plan": "../../plans/" + plan_file, "description": description})
        )
    write_bundle(case_dir, records, bundle, bodies)


def mutate_record_file(out, name, record, mutate):
    """Rewrite one record file in place, keeping its name (a changed artifact)."""
    path = os.path.join(
        out, "cases", name, "bundle", "records", hexof(doc_digest(record)) + ".json"
    )
    changed = copy.deepcopy(record)
    mutate(changed)
    with open(path, "wb") as handle:
        handle.write(pretty(changed))


def build(out):
    plan, manifests = make_plan()
    other, _ = make_plan(per_job="PT30M", total="PT90M")
    pd = doc_digest(plan)

    os.makedirs(os.path.join(out, "plans", "seed-manifests"))
    with open(
        os.path.join(out, "plans", "toyparse-linux-mutate.plan.json"), "wb"
    ) as handle:
        handle.write(pretty(plan))
    with open(
        os.path.join(out, "plans", "toyparse-linux-mutate-30m.plan.json"), "wb"
    ) as handle:
        handle.write(pretty(other))
    for target, manifest in manifests.items():
        with open(
            os.path.join(out, "plans", "seed-manifests", target + ".json"), "wb"
        ) as handle:
            handle.write(pretty(manifest))

    plan_file = "toyparse-linux-mutate.plan.json"
    # The parse_record engine log, encrypted and bundled as ciphertext.
    log, log_ref = sealed("engine log parse_record 1")
    sealed_log = ("private", log_ref)

    def clean_attempts(log_for_first=None):
        return [
            attempt_record(plan, pd, "parse_record", start=0, log=log_for_first),
            attempt_record(plan, pd, "parse_stream", start=60),
            attempt_record(plan, pd, "render_record", start=120),
        ]

    # 1. complete-clean
    atts = clean_attempts(sealed_log)
    camp = campaign_record(
        pd, [disposition(pd, a["payload"]["job_id"], a) for a in atts], instant(181)
    )
    bundle = bundle_record(pd, [camp] + atts, instant(182))
    write_case(
        out,
        "complete-clean",
        plan_file,
        "Every job reached its budget with no finding; one encrypted engine log is bundled.",
        [camp] + atts,
        bundle,
        [log],
    )
    clean = (atts, camp, bundle)

    # 2. incomplete-with-finding
    a1 = attempt_record(plan, pd, "parse_record", start=0)
    a2 = attempt_record(plan, pd, "parse_stream", start=60, findings=["crash"])
    a3 = attempt_record(
        plan,
        pd,
        "render_record",
        start=120,
        result="abandoned",
        outcome="host_lost",
        used="PT20M",
    )
    atts = [a1, a2, a3]
    camp = campaign_record(
        pd, [disposition(pd, a["payload"]["job_id"], a) for a in atts], instant(181)
    )
    bundle = bundle_record(pd, [camp] + atts, instant(182))
    write_case(
        out,
        "incomplete-with-finding",
        plan_file,
        "Two jobs reached their budget, one of them with a crash finding (keep-going mode); "
        "the third was abandoned when its host was lost. Valid, incomplete, finding kept.",
        [camp] + atts,
        bundle,
    )

    # 3. retry-complete
    r1 = attempt_record(
        plan,
        pd,
        "render_record",
        start=120,
        result="abandoned",
        outcome="host_lost",
        used="PT20M",
    )
    r2 = attempt_record(plan, pd, "render_record", n=2, start=150)
    first = [a1, attempt_record(plan, pd, "parse_stream", start=60)]
    camp1 = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in first + [r1]],
        instant(141),
    )
    camp2 = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in first]
        + [disposition(pd, "render_record", r2, earlier=[r1])],
        instant(211),
        revision=2,
        supersedes={"revision": 1, "digest": doc_digest(camp1)},
    )
    bundle = bundle_record(pd, [camp2] + first + [r1, r2], instant(212))
    write_case(
        out,
        "retry-complete",
        plan_file,
        "render_record attempt 1 was abandoned and attempt 2 reached the budget. The campaign "
        "record is revision 2 and retains attempt 1. Valid, complete.",
        [camp2] + first + [r1, r2],
        bundle,
    )

    # 4. unsupported-host
    camp = campaign_record(
        pd,
        [disposition(pd, t, None) for t in TARGETS],
        instant(0),
        host_check={
            "status": "unsupported",
            "missing": [{"control": "engine_rss_limit", "mebibytes": 1024}],
        },
    )
    bundle = bundle_record(pd, [camp], instant(0))
    write_case(
        out,
        "unsupported-host",
        plan_file,
        "The host could not demonstrate a required control, so no job started. "
        "Valid, incomplete, no observations.",
        [camp],
        bundle,
    )

    # Negative controls: each differs from a valid case by one change.
    atts, camp, bundle = clean

    # 5. changed-artifact: one attempt file edited, name and pin unchanged.
    write_case(
        out,
        "changed-artifact",
        plan_file,
        "complete-clean with the parse_stream attempt file edited after collection.",
        [camp] + atts,
        bundle,
        [log],
    )
    mutate_record_file(
        out,
        "changed-artifact",
        atts[1],
        lambda r: r["payload"]["observations"].__setitem__("executions", 99_000_000),
    )

    # 6. changed-body: the bundled public log altered.
    write_case(
        out,
        "changed-body",
        plan_file,
        "complete-clean with the bundled engine log ciphertext altered.",
        [camp] + atts,
        bundle,
        [log],
    )
    path = os.path.join(
        out, "cases", "changed-body", "bundle", "bodies", hexof(byte_digest(log))
    )
    with open(path, "wb") as handle:
        handle.write(log.replace(b"stand-in", b"stand-in, altered"))

    # 7. member-unresolved: one pinned record file missing.
    write_case(
        out,
        "member-unresolved",
        plan_file,
        "complete-clean with the render_record attempt file removed from the bundle.",
        [camp] + atts[:2],
        bundle,
        [log],
    )

    # 8. missing-disposition: render_record has no disposition and no attempt.
    camp_m = campaign_record(
        pd, [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2]], instant(181)
    )
    bundle_m = bundle_record(pd, [camp_m] + atts[:2], instant(182))
    write_case(
        out,
        "missing-disposition",
        plan_file,
        "The campaign record omits the required render_record job.",
        [camp_m] + atts[:2],
        bundle_m,
        [log],
    )

    # 9. conflicting-attempts: two different records for render_record attempt 1.
    c1 = attempt_record(plan, pd, "render_record", start=120)
    c2 = attempt_record(
        plan,
        pd,
        "render_record",
        start=120,
        result="abandoned",
        outcome="host_lost",
        used="PT20M",
    )
    camp_c = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2] + [c1]],
        instant(181),
    )
    bundle_c = bundle_record(pd, [camp_c] + atts[:2] + [c1, c2], instant(182))
    write_case(
        out,
        "conflicting-attempts",
        plan_file,
        "Two different records claim render_record attempt 1; the campaign cites one.",
        [camp_c] + atts[:2] + [c1, c2],
        bundle_c,
        [log],
    )

    # 10. disposition-attempt-mismatch: campaign says succeeded, attempt says abandoned.
    d3 = attempt_record(
        plan,
        pd,
        "render_record",
        start=120,
        result="abandoned",
        outcome="host_lost",
        used="PT20M",
    )
    jobs = [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2] + [d3]]
    jobs[2].update(
        {"state": "succeeded", "reason": "budget_reached", "budget_reached": True}
    )
    camp_d = campaign_record(pd, jobs, instant(181))
    bundle_d = bundle_record(pd, [camp_d] + atts[:2] + [d3], instant(182))
    write_case(
        out,
        "disposition-attempt-mismatch",
        plan_file,
        "The campaign reports render_record as succeeded; its cited attempt was abandoned.",
        [camp_d] + atts[:2] + [d3],
        bundle_d,
        [log],
    )

    # 11. identity-mismatch: attempt_id does not recompute.
    i3 = attempt_record(plan, pd, "render_record", start=120)
    i3["payload"]["attempt_id"] = attempt_id(task_id(pd, "render_record"), 7)
    i3["record_id"] = "attempt-" + hexof(i3["payload"]["attempt_id"])
    camp_i = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2] + [i3]],
        instant(181),
    )
    bundle_i = bundle_record(pd, [camp_i] + atts[:2] + [i3], instant(182))
    write_case(
        out,
        "identity-mismatch",
        plan_file,
        "The render_record attempt is numbered 1 but carries the attempt id of attempt 7.",
        [camp_i] + atts[:2] + [i3],
        bundle_i,
        [log],
    )

    # 12. limit-not-demonstrated: parse_record reports a weaker RSS limit.
    weak = copy.deepcopy(LIMITS)
    weak[1]["mebibytes"] = 4096
    l1 = attempt_record(plan, pd, "parse_record", start=0, log=sealed_log, limits=weak)
    camp_l = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in [l1] + atts[1:]],
        instant(181),
    )
    bundle_l = bundle_record(pd, [camp_l, l1] + atts[1:], instant(182))
    write_case(
        out,
        "limit-not-demonstrated",
        plan_file,
        "parse_record reports an RSS limit of 4096 MiB; the plan requires 1024 MiB.",
        [camp_l, l1] + atts[1:],
        bundle_l,
        [log],
    )

    # 14. uncited-attempt: an extra attempt in the collection that no disposition cites.
    u2 = attempt_record(plan, pd, "parse_record", n=2, start=200)
    write_case(
        out,
        "uncited-attempt",
        plan_file,
        "complete-clean plus a parse_record attempt 2 that is a member but is not cited "
        "by any disposition.",
        [camp] + atts + [u2],
        bundle_record(pd, [camp] + atts + [u2], instant(182)),
        [log],
    )

    # 15. attempt-wrong-job: render_record's disposition cites the parse_stream attempt.
    jobs_w = [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2]]
    wrong = disposition(pd, "render_record", atts[1])
    jobs_w.append(wrong)
    camp_w = campaign_record(pd, jobs_w, instant(181))
    write_case(
        out,
        "attempt-wrong-job",
        plan_file,
        "The render_record disposition cites the parse_stream attempt record.",
        [camp_w] + atts[:2],
        bundle_record(pd, [camp_w] + atts[:2], instant(182)),
        [log],
    )

    # 16. short-budget: a self-consistent attempt that planned 30 minutes against a 1 hour plan.
    s3 = attempt_record(
        plan, pd, "render_record", start=120, planned="PT30M", used="PT30M"
    )
    camp_s = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2] + [s3]],
        instant(181),
    )
    write_case(
        out,
        "short-budget",
        plan_file,
        "render_record reports a 30 minute budget, used and reached, and the campaign agrees; "
        "the trusted plan sets 1 hour.",
        [camp_s] + atts[:2] + [s3],
        bundle_record(pd, [camp_s] + atts[:2] + [s3], instant(182)),
        [log],
    )

    # 17. retry-repeated-finding-id: both render_record attempts report render-record-1.
    f1 = attempt_record(
        plan,
        pd,
        "render_record",
        start=120,
        result="abandoned",
        outcome="host_lost",
        used="PT20M",
        findings=["crash"],
    )
    f2 = attempt_record(plan, pd, "render_record", n=2, start=150, findings=["timeout"])
    base_jobs = [disposition(pd, a["payload"]["job_id"], a) for a in atts[:2]]
    camp_f = campaign_record(
        pd,
        base_jobs + [disposition(pd, "render_record", f2, earlier=[f1])],
        instant(211),
    )
    write_case(
        out,
        "retry-repeated-finding-id",
        plan_file,
        "render_record attempt 1 (abandoned) and attempt 2 (budget reached) each report a "
        "finding with the local id render-record-1. Valid, complete, two findings.",
        [camp_f] + atts[:2] + [f1, f2],
        bundle_record(pd, [camp_f] + atts[:2] + [f1, f2], instant(212)),
        [log],
    )

    # 18. public-log-in-mutate: the parse_record engine log has public custody.
    plain = b"#done parse_record: execs 18400000, cov 437, no artifacts\n"
    p1 = attempt_record(
        plan, pd, "parse_record", start=0, log=("public", body_ref(plain, "text/plain"))
    )
    camp_p = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in [p1] + atts[1:]],
        instant(181),
    )
    write_case(
        out,
        "public-log-in-mutate",
        plan_file,
        "complete-clean with the parse_record engine log given public custody and bundled "
        "unencrypted; the plan's profile mutates.",
        [camp_p, p1] + atts[1:],
        bundle_record(pd, [camp_p, p1] + atts[1:], instant(182)),
        [plain],
    )

    # 19. corpus-not-encrypted: the parse_stream corpus manifest has no encryption.
    n2 = attempt_record(plan, pd, "parse_stream", start=60, corpus_sealed=False)
    camp_n = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in [atts[0], n2, atts[2]]],
        instant(181),
    )
    write_case(
        out,
        "corpus-not-encrypted",
        plan_file,
        "complete-clean with the parse_stream corpus manifest referenced without encryption.",
        [camp_n, atts[0], n2, atts[2]],
        bundle_record(pd, [camp_n, atts[0], n2, atts[2]], instant(182)),
        [log],
    )

    # 20. private-body-not-encrypted: a private engine log bundled as plaintext.
    q1 = attempt_record(
        plan,
        pd,
        "parse_record",
        start=0,
        log=("private", body_ref(plain, "text/plain")),
    )
    camp_q = campaign_record(
        pd,
        [disposition(pd, a["payload"]["job_id"], a) for a in [q1] + atts[1:]],
        instant(181),
    )
    write_case(
        out,
        "private-body-not-encrypted",
        plan_file,
        "complete-clean with the parse_record engine log private but bundled unencrypted.",
        [camp_q, q1] + atts[1:],
        bundle_record(pd, [camp_q, q1] + atts[1:], instant(182)),
        [plain],
    )

    # 21. unreferenced-body: a body in bodies/ that no member artifact references.
    extra = b"fixture body that no artifact references\n"
    write_case(
        out,
        "unreferenced-body",
        plan_file,
        "complete-clean with an extra file in bodies/ that no member artifact references.",
        [camp] + atts,
        bundle,
        [log, extra],
    )

    # 13. plan-mismatch: complete-clean verified against a different trusted plan.
    write_case(
        out,
        "plan-mismatch",
        "toyparse-linux-mutate-30m.plan.json",
        "complete-clean verified against a plan with a 30 minute budget per job.",
        [camp] + atts,
        bundle,
        [log],
    )


# ---------------------------------------------------------------- main


def compare(built, committed):
    problems = []
    for base, _, files in os.walk(built):
        for name in files:
            rel = os.path.relpath(os.path.join(base, name), built)
            other = os.path.join(committed, rel)
            if not os.path.exists(other):
                problems.append("missing: " + rel)
            elif not filecmp.cmp(os.path.join(base, name), other, shallow=False):
                problems.append("differs: " + rel)
    for base, _, files in os.walk(committed):
        for name in files:
            rel = os.path.relpath(os.path.join(base, name), committed)
            if name == "expected.json":
                continue
            if not os.path.exists(os.path.join(built, rel)):
                problems.append("extra: " + rel)
    return problems


def main(argv):
    if len(argv) != 2 or argv[1] not in ("build", "check"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 64
    with tempfile.TemporaryDirectory() as tmp:
        built = os.path.join(tmp, "v0")
        build(built)
        if argv[1] == "check":
            problems = compare(built, OUT)
            for problem in problems:
                print("fixtures-v0: " + problem, file=sys.stderr)
            if problems:
                print(
                    "fixtures-v0: committed fixtures differ; run scripts/fixtures-v0.py build",
                    file=sys.stderr,
                )
                return 1
            print("[ok] fixtures-v0: committed fixtures match the builder")
            return 0
        keep = {}
        if os.path.isdir(OUT):
            for base, _, files in os.walk(OUT):
                for name in files:
                    if name == "expected.json":
                        path = os.path.join(base, name)
                        with open(path, "rb") as handle:
                            keep[os.path.relpath(path, OUT)] = handle.read()
            shutil.rmtree(OUT)
        shutil.copytree(built, OUT)
        for rel, data in keep.items():
            os.makedirs(os.path.dirname(os.path.join(OUT, rel)), exist_ok=True)
            with open(os.path.join(OUT, rel), "wb") as handle:
                handle.write(data)
        print("[ok] fixtures-v0: built " + os.path.relpath(OUT, ROOT))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
