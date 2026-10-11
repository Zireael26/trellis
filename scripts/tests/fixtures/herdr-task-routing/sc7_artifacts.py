#!/usr/bin/env python3
"""Build the spec 052 SC7 crafted-artifact fixture set.

One fixture set runs through every place that enforces verdict independence:
the resolver (`family_collapse` over each case's `roles`) and
`hooks/lib/code-reviewer.sh`. The SessionStart hooks plant the same set to prove
none is adopted at startup. Every artifact is internally
consistent -- trails, seats, chosen rows, degraded lists, and the policy SHA
all agree -- so an accept/reject verdict isolates the independence layout.

Usage: sc7_artifacts.py POLICY OUTDIR WORKSPACE PANE NONCE
Writes OUTDIR/<case>.json per case and OUTDIR/manifest.json, a list of
{case, expect: accept|reject, resolver: bool, implementer, why}.
`resolver: false` marks cases that only an artifact validator can judge
(policy binding, degraded bookkeeping).
"""
import datetime as dt
import hashlib
import json
import os
import sys

SINGLE = ("reviewer", "security_reviewer", "merge_reviewer")
VERDICT = set(SINGLE) | {"refuter"}


def entry(cfg, agent, eligible=True, reason="eligible", launcher=True):
    facts = cfg["agents"][agent]
    row = {
        "agent": agent,
        "model": facts["model"],
        "provider": facts["provider"],
        "eligible": eligible,
        "reason": reason,
        "remaining": 0.9,
        "note": "reported",
    }
    if launcher:
        row["launcher"] = "apex" if facts["harness"] == "claude-code" else "pi"
    return row


def chosen_of(row):
    return {key: value for key, value in row.items()
            if key not in ("eligible", "reason")}


def build(cfg, policy_bytes, implementer, verdicts, refuter, workspace, pane,
          nonce, launcher=True, refusals=None):
    """Return one consistent scoped artifact.

    ``verdicts`` maps each single verdict role to None, an agent, or a list
    of eligible trail agents whose first entry is chosen.
    ``refuter`` is ``(trail_agents, seat_agents)``.
    """
    refusals = refusals or {}
    roles = {}
    degraded = []
    for role, spec in cfg["roles"].items():
        if role == "refuter":
            trail_agents, seat_agents = refuter
            trail = [entry(cfg, a, launcher=launcher) for a in trail_agents]
            seats = [entry(cfg, a, launcher=launcher) for a in seat_agents]
            roles[role] = {
                "purpose": spec["purpose"],
                "chosen": chosen_of(seats[0]) if seats else None,
                "trail": trail,
                "refusals": [
                    entry(cfg, a, False, why, launcher)
                    for a, why in refusals.get(role, [])
                ],
                "overflow": None,
                "seats": seats,
                "required_seats": spec["required_seats"],
            }
            if len(seats) < spec["required_seats"]:
                degraded.append(role)
            continue
        if role == "implementer":
            agent = implementer
        elif role in VERDICT:
            agent = verdicts[role]
        else:
            agent = spec["chain"][0]["agent"]
        agents = agent if isinstance(agent, list) else [agent] if agent else []
        trail = [entry(cfg, a, launcher=launcher) for a in agents]
        row = trail[0] if trail else None
        roles[role] = {
            "purpose": spec["purpose"],
            "chosen": chosen_of(row) if row else None,
            "trail": trail,
            "refusals": [
                entry(cfg, a, False, why, launcher)
                for a, why in refusals.get(role, [])
            ],
            "overflow": None,
        }
        if row is None:
            degraded.append(role)
    degraded_verdict = [role for role in degraded if role in VERDICT]
    ready = not degraded_verdict
    facts = cfg["agents"][implementer]
    return {
        "resolved_at": dt.datetime.now(dt.timezone.utc).isoformat(
            timespec="seconds"
        ),
        "resolution_nonce": nonce,
        "roles_policy": {
            "roles_sha256": hashlib.sha256(policy_bytes).hexdigest(),
            "cache_ttl_seconds": cfg["cache_ttl_seconds"],
        },
        "usage_source": "fixture",
        "resolution_scope": {
            "scoped": True,
            "implementer": implementer,
            "implementer_model": facts["model"],
            "implementer_provider": facts["provider"],
            "implementer_family": facts["family"],
            "cross_family_enforced": True,
            "verdict_families_distinct": ready,
            "herdr_workspace_id": workspace,
            "herdr_pane_id": pane,
        },
        "approval_ready": ready,
        "degraded_roles": degraded,
        "degraded_verdict_roles": degraded_verdict,
        "family_collapse": [],
        "roles": roles,
        "claude_roles": cfg.get("claude_roles"),
        "secrets_policy": cfg.get("secrets_policy"),
    }


def cases(cfg, policy_bytes, workspace, pane, nonce):
    def art(implementer, reviewer, security, merge, trail, seats=None, **kw):
        return build(
            cfg, policy_bytes, implementer,
            {"reviewer": reviewer, "security_reviewer": security,
             "merge_reviewer": merge},
            (trail, trail if seats is None else seats),
            workspace, pane, nonce, **kw,
        )

    # Grok retired 2026-10-08: beside a producer and a reviewer in two of the
    # four remaining families, only two refuter families are left, so a
    # healthy panel is 2/3 and the refuter is DEGRADED in every artifact.
    healthy_seats = ["gemini", "opus"]
    out = []

    def add(case, expect, implementer, why, artifact, resolver=True):
        out.append((case, expect, resolver, implementer, why, artifact))

    add("a", "accept", "cheap-2",
        "merge reviewer sol-xhigh shares the reviewer sol's family (openai)",
        art("cheap-2", "sol", "opus", "sol-xhigh", healthy_seats))
    add("b", "accept", "luna",
        "refuter seat opus shares the security and merge family (anthropic)",
        art("luna", "cheap-2", "opus", "opus", healthy_seats))
    add("c", "reject", "cheap-2",
        "security reviewer sol-xhigh shares the reviewer sol's family",
        art("cheap-2", "sol", "sol-xhigh", "opus", healthy_seats))
    add("d-reviewer", "reject", "luna",
        "reviewer sol shares the producer luna's family",
        art("luna", "sol", "opus", "opus", healthy_seats))
    add("d-merge", "reject", "luna",
        "merge reviewer sol-xhigh shares the producer luna's family",
        art("luna", "cheap-2", "opus", "sol-xhigh", healthy_seats))
    add("d-refuter", "reject", "luna",
        "refuter seat sol shares the producer luna's family",
        art("luna", "cheap-2", "opus", "opus", ["gemini", "opus", "sol"]))
    add("e", "reject", "luna",
        "refuter seat cheap-2 shares the reviewer cheap-2's family (meta)",
        art("luna", "cheap-2", "opus", "opus", ["gemini", "opus", "cheap-2"]))
    add("f", "reject", "luna",
        "refuter seats cheap-2 and cheap are both family meta",
        art("luna", "gemini", "opus", "opus", ["cheap-2", "opus", "cheap"]))
    # 1.3.4 layout: every verdict family distinct from every other, so the
    # merge reviewer had no candidate and the refuter one seat. No launcher
    # field, as in an artifact written before spec 052.
    old_refusals = {
        "merge_reviewer": [
            ("opus", "verdict-family-in-use"),
            ("sol-xhigh", "same-family"),
        ],
        "refuter": [
            ("cheap-2", "verdict-family-in-use"),
            ("sol", "same-family"),
            ("opus", "verdict-family-in-use"),
            ("cheap", "verdict-family-in-use"),
        ],
    }
    old = art("luna", "cheap-2", "opus", None, ["gemini"],
              launcher=False, refusals=old_refusals)
    assert old["degraded_roles"] == ["merge_reviewer", "refuter"]
    add("g", "accept", "luna",
        "1.3.4 layout: independence holds; merge and refuter stay DEGRADED",
        old)
    # Launcher binding (SC4): optional, but when present it is the catalog
    # harness's value and a chosen row agrees with its trail.
    forged = art("luna", "cheap-2", "opus", "opus", healthy_seats)
    forged["roles"]["merge_reviewer"]["chosen"]["launcher"] = "pi"
    forged["roles"]["merge_reviewer"]["trail"][0]["launcher"] = "pi"
    add("h-launcher-forged", "reject", "luna",
        "the opus merge row claims launcher pi; its catalog harness is "
        "claude-code", forged)
    split = art("luna", "cheap-2", "opus", "opus", healthy_seats)
    del split["roles"]["merge_reviewer"]["trail"][0]["launcher"]
    add("h-launcher-split", "reject", "luna",
        "the opus merge chosen row says apex but its trail entry has no "
        "launcher", split)
    # Every eligible verdict fallback obeys the rules, not only the chosen row.
    add("i-fallbacks-ok", "accept", "cheap-2",
        "eligible fallbacks in allowed families: reviewer sol, security opus "
        "and sol-xhigh behind astra, merge sol-xhigh",
        art("cheap-2", ["gemini", "sol"], ["astra", "opus", "sol-xhigh"],
            ["opus", "sol-xhigh"], ["sol", "opus"]))
    add("i-reviewer-trail", "reject", "luna",
        "reviewer cheap-2 is chosen but sol, the producer's family, is an "
        "eligible fallback",
        art("luna", ["cheap-2", "sol"], "opus", "opus", healthy_seats))
    add("i-security-trail", "reject", "cheap-2",
        "security reviewer's eligible fallback sol-xhigh shares the "
        "reviewer sol's family",
        art("cheap-2", "sol", ["opus", "sol-xhigh"], "opus", healthy_seats))
    add("i-merge-trail", "reject", "luna",
        "merge reviewer's eligible fallback sol-xhigh shares the producer's "
        "family",
        art("luna", "cheap-2", "opus", ["opus", "sol-xhigh"], healthy_seats))
    add("e-late", "reject", "luna",
        "valid refuter seats followed by an eligible entry in the reviewer's "
        "family",
        art("luna", "cheap-2", "opus", "opus",
            healthy_seats + ["cheap-2"], healthy_seats))
    unbound = json.loads(json.dumps(old))
    unbound["roles_policy"]["roles_sha256"] = hashlib.sha256(
        policy_bytes + b"\n"
    ).hexdigest()
    add("g-policy-sha", "reject", "luna",
        "1.3.4 layout bound to another policy's bytes", unbound,
        resolver=False)
    undegraded = json.loads(json.dumps(old))
    undegraded["degraded_roles"] = []
    undegraded["degraded_verdict_roles"] = []
    undegraded["approval_ready"] = True
    undegraded["resolution_scope"]["verdict_families_distinct"] = True
    add("g-missing-seats", "reject", "luna",
        "1.3.4 layout claiming its missing seats are not DEGRADED", undegraded,
        resolver=False)
    return out


def main():
    policy_path, outdir, workspace, pane, nonce = sys.argv[1:]
    with open(policy_path, "rb") as source:
        policy_bytes = source.read()
    cfg = json.loads(policy_bytes)
    os.makedirs(outdir, exist_ok=True)
    manifest = []
    for case, expect, resolver, implementer, why, artifact in cases(
        cfg, policy_bytes, workspace, pane, nonce
    ):
        with open(os.path.join(outdir, f"{case}.json"), "w") as sink:
            json.dump(artifact, sink, indent=1)
        manifest.append({
            "case": case,
            "expect": expect,
            "resolver": resolver,
            "implementer": implementer,
            "why": why,
        })
    with open(os.path.join(outdir, "manifest.json"), "w") as sink:
        json.dump(manifest, sink, indent=1)


if __name__ == "__main__":
    main()
