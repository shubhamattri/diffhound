# Repository-grounded review

The review must understand a changed flow before reporting a defect or recommending reuse.
The existing diff, grep validators, and peer responses are useful inputs, not proof.
Build bounded, line-numbered evidence from the exact captured Git head, including tests.
Collect the cited function, referenced symbols, callers, settings, and nearby implementations.
Report search limits explicitly; zero textual references never proves dead code.
Use the same collector for primary context and final finding verification.
Normalize primary and peer candidates before a single mandatory pre-wording gate.
The gate distinguishes supported, corrected, contradicted, non-actionable and unverified claims.
Primary output requires a valid findings envelope; unknown prose cannot become a clean empty review.
Legacy mechanical filters do not discard candidates before this gate.
Retain a valid core while removing unsupported impact; never infer execution from source.
Accept model decisions only with complete IDs and exact quotes in the supplied evidence.
Pass the existing voice examples into this gate, then preserve its final bodies verbatim.
Constrain formatting to the checked finding set; reconstruct summary claims from that set.
Final verdicts follow surviving checked severities; low advisory scores alone cannot request changes.
Withhold formatting-generated thread replies until their assertions are source-checked too.
Do not refresh old visible history into a new source-checked review; link earlier rounds.
Missing responses or malformed decisions fail publication; no fail-open fallback.
Verification requests use Anthropic's native JSON schema output contract, not prompt-only
JSON formatting. Local ID, evidence, severity and completion checks still apply, and
refusals or truncated generations remain failures. The schema contains no repository data.
Legacy notes without an unambiguous file, numeric line and severity are archived
as UNVERIFIED, counted in coverage and withheld; locations are never guessed.
Raw inputs are retained before parsing. Up to four verification calls run together,
each capped at 128,000 output tokens and 900 seconds within the remaining
1,200-second stage budget. Every child is reaped. A truncated generation stops
the wave before more batches are launched, even if the provider returned some text.
All located candidates are batched without a separate count limit. Exhausting the deadline
or missing a candidate decision stops publication; a partial review never passes the gate.
Preparation and final reconciliation use the same remaining timeout budget.
Exact citations may refer to any source packet supplied in the same batch and Git head;
fabricated text and paths remain invalid. A wrong evidence line number is corrected only
when its exact path and quote identify one unique supplied source line. Ambiguous matches
are rejected, candidate anchors are unchanged, and correction counts are archived separately.
The formatter cannot select, move or rewrite findings: comments are rendered directly from
the checked set, including when its proposed comment list is incomplete.
Keep unverified candidates in the private archive and report aggregate coverage publicly.
Reserve peer prompt space for instructions, findings, actual diff, and repository context.
Peer completion is transport coverage, not proof that every finding is correct.
Tests use synthetic repositories; no private source or review content belongs in this repo.
Acceptance includes mutation checks, neighboring true defects, bounded retrieval, and live publication.
Deploy only after personal PR checks pass; preserve learned runtime data and active reviews.
The internal `DIFFHOUND_SOURCE_CHECK_ENABLED` handshake skips the old verifier only
for processes that run the final source gate; older running reviews keep their verifier.
