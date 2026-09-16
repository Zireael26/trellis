# Preserve the context rollup as one reviewed change

Status: accepted for the 1.1.0 release preparation.

The operator requested including their committed cleanup of the private
`gotchas.md` and `decisions-log.md` with the computer-use release. The cleanup
retains both original files as byte-identical archives, a manifest of before
and after hashes, and a disposition record beside the shortened active files.

This produces an unusually large private-source diff: most lines are historical
content moved into archives, not new executable behavior. Splitting the archive
copies from the active-file consolidation would leave an intermediate review or
rollback without the complete preservation evidence. Keep that original commit
unchanged and inspect its hashes independently.

The computer-use implementation remains a separate commit. Moving that commit
to another PR would not reduce the archival change below the size cap. This
exception covers the archival consolidation, not arbitrary additional scope;
the PR must retain the size warning and independent reviewer acknowledgement.

Private logs and their archive remain outside the public publisher's allowlist.
The public release carries the portable computer-use profile, its patch and
verification code, and this publication decision. It does not export the
historical operator records or adopt the new release across existing projects.
