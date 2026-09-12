# Security

soapcap handles session transcripts that can contain PHI, so the most
realistic "security issue" here isn't a classic vulnerability — it's a
retention bug: a path where a transcript, note, or other captured content
ends up written to disk, logged, or sent somewhere the README doesn't
document.

If you find one — or any other security-relevant problem — please **don't**
open a public GitHub issue with transcript content, real or synthetic-but-
realistic, pasted into it. Instead email:

**pglockner@gmail.com**

with enough detail to reproduce (command run, expected vs. actual behavior).
A plain description of the bug is enough; no need to attach real session
data.

This is a personal, unfunded project maintained on a best-effort basis —
there's no SLA on response time, but reports are welcome and taken
seriously.
