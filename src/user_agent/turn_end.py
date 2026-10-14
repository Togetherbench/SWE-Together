"""What the simulator is told about where the agent stopped.

The wrappers used to pass ``completing=True`` on every consult, and the prompt
turned that into "** The agent is signaling completion." on every turn. That
sentence is the trigger for "the agent tries to finish but missed requirements",
so every intermediate report looked like a finish, and the simulator had no way
to tell a progress report from a claim of completion.

No classifier can read the agent's stance reliably (reports end in dozens of
ways, in several languages); the simulator can, because it reads the report.
So the prompt now states only what the harness actually knows:

* the agent stopped and is waiting for the user (always true at a consult);
* whether this is the first report of the session, or how many turns the agent
  has been going;
* and leaves "is it finished?" to the simulator, with the report and the
  terminal view as evidence.

The one thing the harness *can* observe is the agent's stop reason when the
harness exposes it (e.g. opencode's ``step_finish.reason``): ``stop`` is the
model ending its turn; anything else (``length``, ``error``, a cap) is not a
deliberate stop and is worth saying.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TurnEnd:
    #: the harness's stop reason for the final step, when known
    #: ("stop" = the model ended its turn; "length" = hit max tokens; "error";
    #: "cap" = killed by the per-exec cap)
    stop_reason: str | None = None
    #: whether the agent emitted any narration this turn
    has_report: bool = True

    def describe(self, turn: int) -> str:
        """One or two plain sentences for the simulator prompt."""
        parts = []
        if self.stop_reason == "cap":
            parts.append("The agent's turn was cut off by the time limit; it did not finish what it was doing.")
        elif self.stop_reason == "length":
            parts.append("The agent's reply was cut off at the output limit; its report below may be incomplete.")
        elif self.stop_reason == "error":
            parts.append("The agent's turn ended with an error.")
        elif not self.has_report:
            parts.append("The agent stopped without saying anything.")
        else:
            parts.append("The agent has stopped and is waiting for you.")
        parts.append(
            "Whether it is finished, pausing between steps, blocked, or asking you something "
            "is for you to judge from its report and the terminal; it has not been told it is done."
        )
        return " ".join(parts)
