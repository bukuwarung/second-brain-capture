---
description: Save content from this conversation (a summary, thread, transcript, analysis) as a searchable note in the team Cortex knowledge base.
argument-hint: [what to save — optional if it's obvious from context]
---

The user wants to save something from this conversation into Cortex, BukuWarung's knowledge base, so teammates can find it and agents can answer questions from it. Your job: identify the content, curate it into ONE self-contained markdown note, and push it with the plugin's uploader script.

**What to save.** If `$ARGUMENTS` names it, use that. Otherwise it is the most recent substantive artifact in this conversation — a summary you wrote, a Slack thread or email you fetched and digested, a meeting transcript, a decision, an analysis. If genuinely ambiguous, ask once.

**Curate, don't dump.** The note must make sense to a teammate with zero context from this session:

- Lead with a short paragraph saying what this is and why it matters.
- Then the content itself, cleanly formatted (headings, lists — not raw tool output, not JSON blobs, not transcripts-of-transcripts).
- End with a `## Source` line: where this came from (e.g. `Slack #payments-ops thread, 2026-07-02`, `Weekly sync recording transcript`, `Analysis of X in session with Claude`).
- Target well under 100KB. The script hard-rejects past 256KB — if the content is bigger, split it into multiple focused notes or summarize harder.

**Sensitivity gate — check BEFORE uploading.** The default destination is the "Team Second Brain" KB, which is visible to **everyone in the org**. The pipeline redacts PII patterns (emails, phones, IDs) and scrubs secret tokens, but it cannot judge business sensitivity. If the content includes private DMs, personal email content, HR/compensation/legal/personnel matters, or anything the user might not want org-wide, STOP and confirm with the user first (offer to trim it or skip the save). When the user explicitly asked to save exactly this content and it's ordinary work material, proceed without asking.

## Steps

1. Compose the curated note and write it to a temp file (e.g. via `mktemp`). Do not include a top-level `#` title — the script adds one.

2. Pick a **slug**: kebab-case, 3–6 content-bearing words, e.g. `q3-payments-incident-summary`, `kyc-vendor-eval-notes`. The slug becomes the record's title in the KB and its upsert key — saving the same slug again later UPDATES that record instead of creating a new one. Pick a **title**: the human display form, e.g. `Q3 payments incident summary`.

3. Run the uploader:

    ```bash
    bash ${CLAUDE_PLUGIN_ROOT}/scripts/save-to-cortex.sh \
      --file <tmpfile> --slug <slug> --title '<title>'
    ```

    Optional: `--kb <kbId>` to target a different knowledge base if the user asks for one.

4. Read the result (one JSON line on stdout; failures print a reason on stderr):
   - `"status":"created"` → tell the user it's saved, visible to the whole org in the Team Second Brain KB, and searchable once indexing completes (typically under a minute). Mention the record id.
   - `"status":"updated"` → same, but note it replaced the earlier version of that note.
   - `"status":"duplicate"` → this exact content was already saved (report the existing record id); nothing was re-uploaded.
   - Failure → relay the stderr reason. Common fixes: missing/invalid credentials → run `/second-brain-capture:setup`; "redaction could not be verified" → Cortex or the redaction agent is unreachable, try again shortly. Never retry by bypassing redaction.

## Rules

- Never upload raw un-curated tool output or an entire conversation verbatim.
- Never set `SECOND_BRAIN_SAVE_ASSUME_CLEAN` — that bypass is for CI only.
- One note per save. If the user wants several things saved, run the flow once per note.
- Don't delete or modify existing KB records from this command; it only creates or updates its own slugs.
