#!/usr/bin/env python3
"""Installed CLI proves canary, deterministic holdout, and next-turn kill-switch rollback."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

from termmesh import termmeshError


def route(cli: Path, env: dict, turn: str, *, route_name: str = "direct", evidence: bool = False, overrides: dict | None = None) -> dict:
    current = Path(env["HOME"]) / ".term-mesh/logs/.turn-current-surface-canary"
    current.parent.mkdir(parents=True, exist_ok=True)
    current.write_text(turn + "\n")
    args = [str(cli), "leader", "turn", "route",
        "--route", route_name, "--task-shape", "multi_unit",
        "--available-workers", "3"]
    if evidence:
        values = {
            "checkout_mode": "isolated",
            "ready_mutating_slices": 2,
            "ownership_disjoint": True,
            "leader_lane_disjoint": True,
            "concurrent_write_overlap": 0,
            "serial_integration": True,
            "resource_health": "passed",
        }
        values.update(overrides or {})
        args.extend(["--checkout-mode", str(values["checkout_mode"])])
        args.extend(["--ready-mutating-slices", str(values["ready_mutating_slices"])])
        if values["ownership_disjoint"]:
            args.append("--ownership-disjoint")
        if values["leader_lane_disjoint"]:
            args.append("--leader-lane-disjoint")
        args.extend(["--concurrent-write-overlap", str(values["concurrent_write_overlap"])])
        if values["serial_integration"]:
            args.append("--serial-integration")
        args.extend(["--resource-health", str(values["resource_health"])])
    result = subprocess.run(args, env=env, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main() -> int:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    cli = app_bin.parents[2] / "Contents" / "Resources" / "bin" / "tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")
    with tempfile.TemporaryDirectory(prefix="leader-canary-e2e-") as home:
        log = Path(home) / ".term-mesh/logs/turns.log"
        log.parent.mkdir(parents=True)
        linked = []
        for turn, timestamp in (
            ("first", "2026-08-26T00:00:00Z"),
            ("last", "2026-09-01T00:00:00Z"),
        ):
            linked.extend([
                {"event": "turn_start", "turn_id": turn, "ts": timestamp, "team": "p"},
                {"event": "turn_route", "turn_id": turn, "ts": timestamp, "team": "p"},
                {"event": "turn_end", "turn_id": turn, "ts": timestamp, "team": "p"},
            ])
        log.write_text("".join(json.dumps(record) + "\n" for record in linked))
        control = Path(home) / "control.json"
        config = {"schema_version": 1, "mode": "shadow", "percent": 0, "kill_switch": False,
                  "supported": True, "healthy": False, "opt_in": False,
                  "health_scope": "execution_host",
                  "project_id": "p", "session_id": "s",
                  "delegation_effective": "delegated",
                  "delegated_overlap_resolution": True,
                  "overlap_canary_capability": True,
                  "overlap_canary_capability_version": 1}
        control.write_text(json.dumps(config))
        control.chmod(0o600)
        env = os.environ.copy()
        env.update({"HOME": home, "TERMMESH_TEAM": "p",
                    "TERMMESH_SURFACE_ID": "surface-canary",
                    "TERMMESH_LEADER_SESSION_ID": "s",
                    "TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH": "false",
                    "TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE": str(control)})
        applied = route(cli, env, "turn-canary", route_name="parallel", evidence=True)
        if (not applied.get("directive")
                or applied["record"].get("policy_applied")
                or applied["record"].get("overlap_canary") is not True
                or applied["directive"].get("execution") != "overlap_canary"):
            raise termmeshError(f"eligible canary did not apply: {applied}")

        env.update({"TERMMESH_LEADER_PARTICIPATION_MODE": "canary",
                    "TERMMESH_LEADER_PARTICIPATION_PERCENT": "100",
                    "TERMMESH_LEADER_PARTICIPATION_SUPPORTED": "true",
                    "TERMMESH_LEADER_PARTICIPATION_HEALTHY": "true",
                    "TERMMESH_LEADER_PARTICIPATION_OPT_IN": "true"})
        control.write_text("not-json")
        invalid_configured = route(
            cli, env, "turn-invalid-configured-control",
            route_name="parallel", evidence=True
        )
        if (invalid_configured["record"].get("policy_applied")
                or invalid_configured["record"].get("policy_mode") != "off"
                or invalid_configured["record"].get("cohort") != "static"
                or invalid_configured["record"].get("overlap_canary") is not False
                or invalid_configured.get("directive") is not None):
            raise termmeshError(
                f"invalid configured control fell back to environment canary: {invalid_configured}"
            )

        env["TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE"] = "   "
        blank_configured = route(
            cli, env, "turn-blank-configured-control",
            route_name="parallel", evidence=True
        )
        if (blank_configured["record"].get("policy_applied")
                or blank_configured["record"].get("policy_mode") != "off"
                or blank_configured["record"].get("cohort") != "static"
                or blank_configured["record"].get("overlap_canary") is not False
                or blank_configured.get("directive") is not None):
            raise termmeshError(
                f"blank configured control fell back to environment canary: {blank_configured}"
            )

        env["TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE"] = str(control)
        control.write_text(json.dumps(config))
        for key in ("TERMMESH_LEADER_PARTICIPATION_MODE",
                    "TERMMESH_LEADER_PARTICIPATION_PERCENT",
                    "TERMMESH_LEADER_PARTICIPATION_SUPPORTED",
                    "TERMMESH_LEADER_PARTICIPATION_HEALTHY",
                    "TERMMESH_LEADER_PARTICIPATION_OPT_IN"):
            env.pop(key, None)

        for session_value in (None, "   "):
            if session_value is None:
                env.pop("TERMMESH_LEADER_SESSION_ID", None)
            else:
                env["TERMMESH_LEADER_SESSION_ID"] = session_value
            missing_session = route(
                cli, env, f"turn-missing-session-{session_value!r}",
                route_name="parallel", evidence=True
            )
            if (missing_session["record"].get("overlap_canary") is not False
                    or missing_session.get("directive") is not None
                    or missing_session["record"].get("policy_mode") != "off"
                    or missing_session["record"].get("cohort") != "static"):
                raise termmeshError(
                    f"missing or blank leader session enabled overlap: {missing_session}"
                )
        env["TERMMESH_LEADER_SESSION_ID"] = "s"

        for field, value in ((
            ("schema_version", 2),
            ("project_id", "foreign-project"),
            ("session_id", "other-session"),
        )):
            config.update({"schema_version": 1, "project_id": "p", "session_id": "s",
                           "delegated_overlap_resolution": True,
                           "overlap_canary_capability": True,
                           "overlap_canary_capability_version": 1,
                           "supported": True, "kill_switch": False})
            config[field] = value
            control.write_text(json.dumps(config))
            boundary = route(cli, env, f"turn-boundary-{field}", route_name="parallel", evidence=True)
            if boundary["record"].get("overlap_canary") is not False:
                raise termmeshError(f"{field} enabled overlap: {boundary}")

        config.update({"schema_version": 1, "project_id": "p", "session_id": "s",
                       "delegated_overlap_resolution": True,
                       "overlap_canary_capability": True,
                       "overlap_canary_capability_version": 1,
                       "supported": True, "kill_switch": False})
        control.write_text(json.dumps(config))
        control.chmod(0o644)
        over_permissive = route(cli, env, "turn-boundary-owner-mode", route_name="parallel", evidence=True)
        if over_permissive["record"].get("overlap_canary") is not False:
            raise termmeshError(f"over-permissive control enabled overlap: {over_permissive}")
        control.chmod(0o600)

        env["TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH"] = "true"
        env_killed = route(cli, env, "turn-boundary-env-kill", route_name="parallel", evidence=True)
        if env_killed["record"].get("overlap_canary") is not False:
            raise termmeshError(f"environment kill switch did not deny overlap: {env_killed}")
        env["TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH"] = "false"

        for field, value in ((
            ("delegated_overlap_resolution", False),
            ("overlap_canary_capability", False),
            ("overlap_canary_capability_version", 0),
            ("delegation_effective", "leaderFirst"),
            ("supported", False),
        )):
            config["delegated_overlap_resolution"] = True
            config["overlap_canary_capability"] = True
            config["overlap_canary_capability_version"] = 1
            config["delegation_effective"] = "delegated"
            config["supported"] = True
            config[field] = value
            control.write_text(json.dumps(config))
            boundary = route(cli, env, f"turn-boundary-{field}", route_name="parallel", evidence=True)
            if (boundary["record"].get("overlap_canary") is not False
                    or (boundary.get("directive") or {}).get("execution") == "overlap_canary"):
                raise termmeshError(f"{field} enabled overlap: {boundary}")
        config["overlap_canary_capability"] = True
        config["overlap_canary_capability_version"] = 1
        config["delegation_effective"] = "delegated"
        config["delegated_overlap_resolution"] = True
        config["supported"] = True
        deviation = route(cli, env, "turn-route-deviation", route_name="direct", evidence=True)
        if deviation["record"].get("overlap_canary") is not False:
            raise termmeshError(f"route deviation enabled overlap: {deviation}")

        for field, value in ((
            ("checkout_mode", "shared"),
            ("ready_mutating_slices", 1),
            ("ownership_disjoint", False),
            ("leader_lane_disjoint", False),
            ("concurrent_write_overlap", 1),
            ("serial_integration", False),
            ("resource_health", "failed"),
        )):
            control.write_text(json.dumps(config))
            boundary = route(
                cli, env, f"turn-evidence-{field}", route_name="parallel",
                evidence=True, overrides={field: value}
            )
            if boundary["record"].get("overlap_canary") is not False:
                raise termmeshError(f"{field} enabled overlap: {boundary}")

        config["mode"] = "shadow"
        control.write_text(json.dumps(config))
        shadow = route(cli, env, "turn-shadow", route_name="parallel", evidence=True)
        if (not shadow.get("directive")
                or shadow["record"].get("policy_mode") != "shadow"
                or shadow["record"].get("policy_applied")
                or shadow["record"].get("overlap_canary") is not True):
            raise termmeshError(f"Shadow mode changed the live route: {shadow}")

        config["mode"] = "canary"
        config["project_id"] = "missing-project"
        control.write_text(json.dumps(config))
        unhealthy = route(cli, env, "turn-unhealthy", route_name="parallel", evidence=True)
        if unhealthy.get("directive") is not None \
           or unhealthy["record"].get("policy_applied"):
            raise termmeshError(
                f"missing execution-host health did not fail closed: {unhealthy}"
            )
        config["project_id"] = "p"

        config["kill_switch"] = True
        control.write_text(json.dumps(config))
        killed = route(cli, env, "turn-killed", route_name="parallel", evidence=True)
        if killed.get("directive") is not None or killed["record"].get("policy_applied"):
            raise termmeshError(f"kill switch did not affect next turn: {killed}")

        config.update({"kill_switch": False, "mode": "canary", "percent": 0,
                       "opt_in": True})
        control.write_text(json.dumps(config))
        holdout1 = route(cli, env, "turn-holdout-1", route_name="parallel", evidence=True)
        holdout2 = route(cli, env, "turn-holdout-2", route_name="parallel", evidence=True)
        cohorts = [holdout1["record"].get("cohort"), holdout2["record"].get("cohort")]
        if cohorts != ["holdout", "holdout"]:
            raise termmeshError(f"zero-percent holdout is not deterministic: {cohorts}")
        if (holdout1["record"].get("policy_applied")
                or holdout1["record"].get("overlap_canary") is not True):
            raise termmeshError(
                f"general holdout changed or delegated overlap was blocked: {holdout1}"
            )

    print("PASS: delegated overlap applies while ordinary holdout and kill switch stay closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
