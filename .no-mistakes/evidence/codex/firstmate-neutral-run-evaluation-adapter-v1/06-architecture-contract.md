### Neutral run-evaluation projection

`bin/fm-run-evaluation-export.sh` is a manually invoked adapter from immutable `governance.run-evaluation.v1` artifacts to the fixed local snapshot `state/cockpit-run-evaluation.json`.
The governance contract and all scoring semantics remain owned by `00_Architektur`; FirstMate carries a digest-pinned validator copy only so publication never depends on another repository at runtime.
The adapter does not observe or calculate a score, rank, recommendation, or routing decision.
It preserves the contract's separate model, execution-harness, and full-route comparison identities and only removes source-only fields through an explicit projection.
The v1 cohort representation is hash-only; whether a future consumer also needs bounded readable context axes remains an explicit open architecture decision.
Only `synthetic`, `public`, and `internal_non_sensitive` records whose evidence is already labelled `surface_labelled` can enter the snapshot.
Invalid, underclassified, sensitive, productive, non-surface, credential-shaped, or conflicting inputs are counted as withheld without copying their content into the consumer document.
The rolling snapshot keeps the newest immutable revision per run and then retains the newest evaluations first when its 100-record or 262,144-byte limit truncates the candidate set.
That recency policy is deterministic transport retention, not a quality rank, but consumers must treat a truncated snapshot as a recent sample rather than a complete comparison population.
The withheld summary reports `record_limit` and `byte_limit` alongside validation, classification, redaction, duplicate, revision, and identity conflicts without carrying rejected content; the digest-bound redaction policy owns that complete reason-code vocabulary.
The v1 snapshot declares a 300-second consumer freshness window and replaces the previous complete file atomically.
Whether 300 seconds remains the right window and how consumers present it for a manually generated export remain explicit open architecture decisions.
The digest-pinned validator comes from the governance contract marked decided in ADR-0016 at `codex/run-evaluation-contract-v1@b5f4104f93d075cd9140c4dcb6cf06fbeb1501ac`; its provenance records truthfully that this accepted source was not yet on architecture `main` when copied.
No watcher, daemon, spawn path, teardown path, or routing path invokes this adapter.

On a Pi primary, supervision is default-on: the watcher extension can hand eligible task-local rows from an ordinary actionable wake, plus selected fleet-wide heartbeat reviews, to a persistent in-process supervision conversation while main-only rows remain on the captain-facing path.
The branch handles those rows, stores the outcome durably, and merges it back into main.
A captain-facing outcome persists as one exact, sequence-keyed visible transcript entry and then opens one sequence-keyed processing turn on main, which only main's sequence-bound acknowledgement closes.
[docs/pi-supervision-branch.md](pi-supervision-branch.md) owns row eligibility, dispatch architecture, deterministic outcome delivery, and processing re-presentation, while the generated [Pi supervision protocol](supervision-protocols/pi.md) owns MAIN's merged-event handling and acknowledgement duty; every other harness keeps the wake-to-main path unchanged.


Configuration ownership excerpts

/home/layderer/.no-mistakes/worktrees/1f4dc39dc607/01M2GWBNC25E5VJ0T11VS3703M/docs/scripts.md:19:| `fm-run-evaluation-export.sh` | Validate, redact, and atomically publish the neutral Cockpit run-evaluation snapshot |
/home/layderer/.no-mistakes/worktrees/1f4dc39dc607/01M2GWBNC25E5VJ0T11VS3703M/docs/configuration.md:13:`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, scout reports, immutable neutral evaluation inputs under `data/run-evaluations/`, and explicitly installed content-addressed extension packages under `data/extensions/packages/`.
/home/layderer/.no-mistakes/worktrees/1f4dc39dc607/01M2GWBNC25E5VJ0T11VS3703M/docs/configuration.md:14:`state/` holds runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, the redacted rolling snapshot `state/cockpit-run-evaluation.json`, inactive terminal-outcome receipts under `state/terminal-outcomes/`, enabled extension working namespaces under `state/extensions/`, away-mode state, generated Relay artifacts, parent-side remote ledger copies under `state/secondmate-summary-cache/`, one-shot Bearings reconcile requests under `state/reconcile-notify/`, private secondmate config-reread generations with their retry and quarantine state, per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`), and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
/home/layderer/.no-mistakes/worktrees/1f4dc39dc607/01M2GWBNC25E5VJ0T11VS3703M/docs/configuration.md:27:`bin/fm-run-evaluation-export.sh` is the only producer of `state/cockpit-run-evaluation.json`; its header owns source selection, fixed destination, validation, redaction, limits, and atomic publication.
