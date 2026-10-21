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
* the agent's stop reason when the harness exposes it (e.g. opencode's
  ``step_finish.reason``): ``stop`` is the model ending its turn; anything else
  (``length``, ``error``, a cap) is not a deliberate stop and is worth saying;
* whether the report ends by asking the user for something.

That last fact is the one the harness can observe and the simulator cannot be
left to weigh for itself. In the first pilot of this prompt the simulator,
told only that "whether it is blocked or asking you something is for you to
judge", answered 44% of the agent's explicit requests (down from 64% under the
previous prompt with the same model), and 13 of 218 sessions ended with the
agent asking for help on three or more of its last four reports. A request the
user cannot literally grant ("please enable network access") still gets an
answer from a real user ("no gh here, work from the local checkout"); silence
ends the session. The detector is deliberately simple and conservative: a
question mark at the end of the report, or a plain request for input in the
last sentences. Its verdict is stated as a fact, and when the agent asked and
the simulator still chose silence, the wrapper asks once more.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

#: The report's last sentences ask the user for a decision, a value, or an action.
#: Matched against the tail of the report only (see ASKS_TAIL_CHARS), so a
#: question answered earlier in the same report does not count.
_ASKS_USER = re.compile(
    r"(?:"
    r"\?\s*(?:\*\*|`|\))?\s*$"                                   # ends with a question
    r"|\b(?:please|pls|kindly)\s+(?:provide|share|send|enable|allow|confirm|tell me|let me know|advise|specify|paste|upload|point me)"
    r"|\blet me know\b"
    r"|\b(?:which|what)\s+(?:option|approach|one|branch|remote|path|file|value|url|version)\b.*\b(?:do you|would you|should i|shall i|you want|you prefer|to use)\b"
    r"|\b(?:do|would|should) you (?:want|like|prefer) (?:me )?to\b"
    r"|\b(?:should|shall|can|may) i (?:proceed|continue|go ahead|start|implement|apply|push|commit|remove|delete|also)\b"
    r"|\bwant me to\b"
    r"|\b(?:awaiting|waiting for|need|needs|requires?) your (?:input|decision|confirmation|guidance|go-ahead|approval|answer|reply)\b"
    r"|\byour call\b"
    r"|\b(?:proceed|go ahead|continue) (?:with|on|to)\b[^.\n]*\?"
    r")",
    re.IGNORECASE,
)
#: A question addressed to the user somewhere in the closing sentences, even when
#: statements follow it ("Can you enable access? No code changes are needed.").
#: `??` is code (nullish coalescing), `?q=` is a URL query, neither is a question.
_CLOSING_QUESTION = re.compile(r"(?<![?=])\?(?![?\w=])")
#: How much of the report tail the detector reads.
ASKS_TAIL_CHARS = 600
#: How many closing sentences may follow the question and still count.
ASKS_CLOSING_SENTENCES = 4


def _closing_sentences(tail: str, n: int = ASKS_CLOSING_SENTENCES) -> str:
    parts = re.split(r"(?<=[.?!])\s+", tail)
    return " ".join(parts[-n:])


def report_asks_user(report: str | None) -> bool:
    """True when the agent's report ends by asking the user for something.

    Looks at the last ASKS_TAIL_CHARS characters only; strips trailing markdown
    and whitespace so "Proceed?**" and "Proceed? " both count. A question in
    the last few sentences counts even if statements follow it.
    """
    if not report:
        return False
    tail = report.strip()[-ASKS_TAIL_CHARS:]
    tail = re.sub(r"[\s*_`>]+$", "", tail)
    if _ASKS_USER.search(tail):
        return True
    closing = re.sub(r"`[^`]*`", "", _closing_sentences(tail))   # ignore inline code
    return bool(_CLOSING_QUESTION.search(closing))


@dataclass(frozen=True)
class TurnEnd:
    #: the harness's stop reason for the final step, when known
    #: ("stop" = the model ended its turn; "length" = hit max tokens; "error";
    #: "cap" = killed by the per-exec cap)
    stop_reason: str | None = None
    #: whether the agent emitted any narration this turn
    has_report: bool = True
    #: whether that narration ends by asking the user for a decision or input
    asks_user: bool = False

    def describe(self, turn: int) -> str:
        """One to three plain sentences for the simulator prompt."""
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
        if self.asks_user:
            parts.append(
                "Its report ends by asking you for something: a decision, a value, or an action. "
                "Answer it. If you cannot or will not give what it asks for, say so and tell it what "
                "to do instead (for example, that there is no network access here and it should work "
                "from the local checkout). A user who stays silent when asked ends the session."
            )
        else:
            parts.append(
                "Whether it is finished, pausing between steps, or blocked is for you to judge from "
                "its report and the terminal; it has not been told it is done."
            )
        return " ".join(parts)
