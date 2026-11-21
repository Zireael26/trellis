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


def build(cfg, policy_bytes, implementer, verdicts, refuter, scope, terminal,
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
            "hc_scope": scope,
            "hc_terminal_id": terminal,
        },
        "approval_ready": ready,
        "degraded_roles": degraded,
        "degraded_verdict_roles": degraded_verdict,
        "family_collapse": [],
        "roles": roles,
        "claude_roles": cfg.get("claude_roles"),
        "secrets_policy": cfg.get("secrets_policy"),
    }


def cases(cfg, policy_bytes, scope, terminal, nonce):
    def art(implementer, reviewer, security, merge, trail, seats=None, **kw):
        return build(
            cfg, policy_bytes, implementer,
            {"reviewer": reviewer, "security_reviewer": security,
             "merge_reviewer": merge},
            (trail, trail if seats is None else seats),
            scope, terminal, nonce, **kw,
        )

    # Owner roster 2026-11-10: five families exist (openai, anthropic, google,
    # meta, deepseek), so beside a producer and a reviewer in two of them three
    # refuter families remain and a healthy panel is 3/3 once the prepaid
    # OpenCode Go seats (muse, deepseek) are live. Implementers come from the
    # implementer chain (anthropic or openai) and every verdict seat from its
    # own role's chain, since the validators reject any row outside policy.
    # Neon is the primary Google reviewer; case b seats its Carbon fallback.
    healthy_seats = ["deepseek", "muse", "opus"]
    out = []

    def add(case, expect, implementer, why, artifact, resolver=True):
        out.append((case, expect, resolver, implementer, why, artifact))

    add("a", "accept", "haiku",
        "merge reviewer sol-xhigh shares the security reviewer sol-xhigh's "
        "family (openai)",
        art("haiku", "neon", "sol-xhigh", "sol-xhigh",
            ["deepseek", "muse", "sol"]))
    add("b", "accept", "terra-medium",
        "refuter seat opus shares the security and merge family (anthropic); "
        "Carbon reviews and the Go seats complete a 3/3 panel",
        art("terra-medium", "carbon", "opus", "opus", healthy_seats))
    add("c", "reject", "haiku",
        "security reviewer sol-xhigh shares the reviewer sol's family",
        art("haiku", "sol", "sol-xhigh", "sol-xhigh",
            ["deepseek", "muse", "gemini"]))
    add("d-reviewer", "reject", "terra-medium",
        "reviewer sol shares the producer terra-medium's family",
        art("terra-medium", "sol", "opus", "opus", healthy_seats))
    add("d-merge", "reject", "terra-medium",
        "merge reviewer sol-xhigh shares the producer terra-medium's family",
        art("terra-medium", "neon", "opus", "sol-xhigh", healthy_seats))
    add("d-refuter", "reject", "terra-medium",
        "refuter seat sol shares the producer terra-medium's family",
        art("terra-medium", "neon", "opus", "opus", ["opus", "sol"]))
    add("e", "reject", "terra-medium",
        "refuter seat gemini shares the reviewer neon's family (google)",
        art("terra-medium", "neon", "opus", "opus", ["opus", "gemini"]))
    add("f", "reject", "terra-medium",
        "refuter seats gemini and neon-low are both family google",
        art("terra-medium", None, "opus", "opus", ["gemini", "neon-low", "opus"]))
    # 1.3.4 layout: every verdict family distinct from every other, so the
    # merge reviewer had no candidate and, with the three families then left,
    # the refuter none either. No launcher field, as in an artifact written before
    # spec 052.
    old_refusals = {
        "merge_reviewer": [
            ("opus", "verdict-family-in-use"),
            ("sol-xhigh", "same-family"),
        ],
        "refuter": [
            ("gemini", "verdict-family-in-use"),
            ("neon-low", "verdict-family-in-use"),
            ("sol", "same-family"),
            ("opus", "verdict-family-in-use"),
        ],
    }
    old = art("terra-medium", "neon", "opus", None, [],
              launcher=False, refusals=old_refusals)
    assert old["degraded_roles"] == ["merge_reviewer", "refuter"]
    add("g", "accept", "terra-medium",
        "1.3.4 layout: independence holds; merge and refuter stay DEGRADED",
        old)
    # Launcher binding (SC4): optional, but when present it is the catalog
    # harness's value and a chosen row agrees with its trail.
    forged = art("terra-medium", "neon", "opus", "opus", healthy_seats)
    forged["roles"]["merge_reviewer"]["chosen"]["launcher"] = "pi"
    forged["roles"]["merge_reviewer"]["trail"][0]["launcher"] = "pi"
    add("h-launcher-forged", "reject", "terra-medium",
        "the opus merge row claims launcher pi; its catalog harness is "
        "claude-code", forged)
    split = art("terra-medium", "neon", "opus", "opus", healthy_seats)
    del split["roles"]["merge_reviewer"]["trail"][0]["launcher"]
    add("h-launcher-split", "reject", "terra-medium",
        "the opus merge chosen row says apex but its trail entry has no "
        "launcher", split)
    # Every eligible verdict fallback obeys the rules, not only the chosen row.
    add("i-fallbacks-ok", "accept", "terra-medium",
        "eligible fallbacks in allowed families: reviewer gemini behind neon",
        art("terra-medium", ["neon", "gemini"], ["opus"], ["opus"], ["opus"]))
    add("i-reviewer-trail", "reject", "terra-medium",
        "reviewer neon is chosen but sol, the producer's family, is an "
        "eligible fallback",
        art("terra-medium", ["neon", "sol"], "opus", "opus", healthy_seats))
    # Exercise rule 1 on security_reviewer's eligible fallback trail.
    add("i-security-trail", "reject", "terra-medium",
        "security reviewer's eligible fallback sol-xhigh shares the "
        "producer's family",
        art("terra-medium", "neon", ["opus", "sol-xhigh"], "opus", healthy_seats))
    add("i-merge-trail", "reject", "terra-medium",
        "merge reviewer's eligible fallback sol-xhigh shares the producer's "
        "family",
        art("terra-medium", "neon", "opus", ["opus", "sol-xhigh"], healthy_seats))
    add("e-late", "reject", "terra-medium",
        "valid refuter seats followed by an eligible entry in the reviewer's "
        "family",
        art("terra-medium", "neon", "opus", "opus",
            healthy_seats + ["gemini"], healthy_seats))
    unbound = json.loads(json.dumps(old))
    unbound["roles_policy"]["roles_sha256"] = hashlib.sha256(
        policy_bytes + b"\n"
    ).hexdigest()
    add("g-policy-sha", "reject", "terra-medium",
        "1.3.4 layout bound to another policy's bytes", unbound,
        resolver=False)
    undegraded = json.loads(json.dumps(old))
    undegraded["degraded_roles"] = []
    undegraded["degraded_verdict_roles"] = []
    undegraded["approval_ready"] = True
    undegraded["resolution_scope"]["verdict_families_distinct"] = True
    add("g-missing-seats", "reject", "terra-medium",
        "1.3.4 layout claiming its missing seats are not DEGRADED", undegraded,
        resolver=False)
    return out


def main():
    policy_path, outdir, scope, terminal, nonce = sys.argv[1:]
    with open(policy_path, "rb") as source:
        policy_bytes = source.read()
    cfg = json.loads(policy_bytes)
    os.makedirs(outdir, exist_ok=True)
    manifest = []
    for case, expect, resolver, implementer, why, artifact in cases(
        cfg, policy_bytes, scope, terminal, nonce
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
