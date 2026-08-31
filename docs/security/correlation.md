# Correlation

Correlation turns recent, non-expected signals into bounded hypotheses. It is
not a linear point counter.

## Subject and hypothesis grouping

Signals are selected by canonical subject key. A hypothesis key combines the
category with the signal correlation key, or with the detector when no
correlation key exists. A subject can produce at most 16 current hypotheses, and
an assessment considers at most 256 retained signals.

Signals matched by active expectations are counted as expected observations but
do not contribute to the hypothesis score.

## Time windows

Each category has a bounded window:

| Window | Categories |
| --- | --- |
| 30 seconds | transport, entity |
| 60 seconds | interaction, world |
| 90 seconds | movement |
| 120 seconds | economy, inventory, player integrity, weapon, client integrity, connection |
| 300 seconds | combat, resource integrity |

Contribution decays with a half-life equal to half the category window. Signals
outside the window no longer contribute.

## Independence and score

`rootEventId`, `requestId`, and `traceId` collapse related signals. When several
signals share one root, only the strongest contribution for that root is used.
Without one of those references, a signal ID is its own root.

For each independent root, contribution is derived from evidence-class weight,
severity weight, signal confidence, and decay. Roots combine non-linearly so
additional observations have diminishing returns. Evidence-class diversity and
multiple independent roots provide only bounded adjustments.

Hypotheses expose:

- category and detector/correlation key;
- current severity and confidence;
- signal count and independent evidence count;
- evidence classes and stable codes;
- oldest/latest contributing timestamps;
- whether all evidence is weak.

Weak-only hypotheses are capped at 0.64 confidence.

## Assessment and cases

The assessment reports overall confidence/severity, recent and expected signal
counts, active expectations, and sorted hypotheses. The default case threshold is
0.42; the service classifies confidence at or above 0.58 as review-level. These
are current engine constants, not production-calibrated promises.

The case engine uses a user identity when available, otherwise the canonical
subject key, to avoid opening duplicate active cases for the same hypothesis.

## Limits

Correlation is in-memory and bounded. It does not perform machine learning,
cross-server analytics, long-term player profiling, or automated attribution of
offensive software. Thresholds, windows, and weights have unit coverage but not
live gameplay calibration.
