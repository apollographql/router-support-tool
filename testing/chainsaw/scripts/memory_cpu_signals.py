"""
Reads the memory/CPU signals the spec documents (specs/collection/base_spec.md, "Memory and CPU
information collected") and finds them in the kubelet's stats.

Shared by assert_documented_memory_cpu_signals.py and wait_for_kubelet_stats.py.
"""
import os
import re

# The spec in this repo, for runs that don't point MEMORY_CPU_SPEC_FILE at another copy.
DEFAULT_SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "specs", "collection", "base_spec.md")


def documented_signals(spec_text, source):
    """
    Collects every signal the spec says to expect from a given source.

    The spec's "Memory and CPU information collected" table in specs/collection/base_spec.md
    lists what the bundle should contain. This reads the expected signals from that table.
    It returns the names in the rows whose Source cell contains `source`.
    """
    signals = []
    base = ""
    for line in spec_text.splitlines():
        cells = line.split("|")
        # cells[0] is what precedes the row's leading pipe, cells[1] is Signal, cells[2] Source.
        if len(cells) < 3 or source not in cells[2]:
            continue
        # A row's first cell lists signal names in backticks. A name that starts with "_" is
        # shorthand for the previous full name with its last word swapped. For example, the cell
        # `apollo_router_jemalloc_allocated`, `_active` names two signals:
        # apollo_router_jemalloc_allocated and apollo_router_jemalloc_active.
        for token in re.findall(r"`([^`]*)`", cells[1]):
            if token.startswith("_"):
                signals.append(base + token)
            else:
                signals.append(token)
                base = token.rsplit("_", 1)[0]
    return signals


def lookup(stats, signal):
    """
    Finds a documented kubelet signal in a container's stats.

    The spec names kubelet signals as dotted paths, for example, `memory.workingSetBytes`,
    that match the nesting in the kubelet's Summary API JSON. This follows that path through the
    container's stats and returns the value, or None if any step is missing, so that the caller
    can detect a documented signal the bundle lacks.
    """
    for key in signal.split("."):
        # stats is the part of the record reached so far. A step can land on something that isn't
        # a dict, such as "memory": null, so check before every lookup.
        if not isinstance(stats, dict) or key not in stats:
            return None
        stats = stats[key]
    return stats
