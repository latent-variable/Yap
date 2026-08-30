"""Pytest wiring for the backend suite.

The full suite costs ~17 minutes of pegged CPU, and nearly all of it comes from a
handful of cases: one that synthesizes a 44k-char document, a few that pull in a
second heavy runtime (torch, for Pocket), and the voice-breadth sweeps. A default
run that expensive is a run nobody makes, which is worse than a smaller one they
do.

So those are marked `slow` and are OFF by default:

    pytest tests/                # fast set — every code path, one cheap case each
    pytest tests/ --runslow      # everything, including scale, Pocket and CoreML

**This changes SELECTION only.** No test's inputs, bounds or assertions were
weakened to make the default faster — every slow case is intact and still runs
under `--runslow`. Deselected cases report as skipped rather than vanishing, so
the default run says out loud what it did not cover.

Run `--runslow` before cutting a release, and whenever you touch synthesis,
chunking, the Pocket engine or the provider path.
"""
import pytest


def pytest_addoption(parser):
    parser.addoption("--runslow", action="store_true", default=False,
                     help="also run the slow cases (scale synthesis, Pocket/torch, CoreML)")


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "slow: heavy case — scale synthesis, a torch/CoreML load, or a real-time "
        "wait. Deselected unless --runslow is given.")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--runslow"):
        return
    skip_slow = pytest.mark.skip(reason="slow — pass --runslow to include")
    for item in items:
        if "slow" in item.keywords:
            item.add_marker(skip_slow)
