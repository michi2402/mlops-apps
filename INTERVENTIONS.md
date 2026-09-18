# Interventions log

Append one entry per manual action taken during a validation run that
`scripts/bootstrap-k8s-native.sh` / `RUNBOOK.md` did not already automate — i.e. anything beyond
the three operator actions in `RUNBOOK.md`. An empty log for a given run is a result, not an
omission: it means the run converged without further operator action.

Format per entry:

```
## <UTC timestamp> — <one-line summary>
Environment: datalab | local
What failed / what triggered the intervention:
What was done:
Evidence: evidence/<env>/<id>-*.txt
```

No entries yet — this file is populated during a validation campaign run (see
`latex/VALIDATION_CAMPAIGN.md`), not ahead of one.
