Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. Finding A is rejected (`addressed: "rejected-<date>"` or equivalent
   phrasing), with a one-line reason that the behavior is intentional
   and documented (by-design caller-generated opaque owner tokens),
   not a real security gap.

2. Finding B is NOT accepted as-is and is NOT rejected outright — it is
   downgraded (severity corrected away from `high`, e.g. to `low` or
   `medium`) with a reason citing the missing concrete `suggestion`
   ("a finding without a clear suggestion should not be high or
   critical") and/or its vague, non-actionable description.

3. Finding C is accepted as-is — it names a real file:line, has a
   concrete suggestion, a severity consistent with a coverage gap, and
   the response does not invent a reason to downgrade or reject a
   well-formed finding.

4. Finding D has its `confidence` corrected downward from `high` to at
   most `medium`, with a reason that the claim was inferred from
   function names/patterns without reading the surrounding parser or
   write-path code — the response must NOT also change D's severity on
   that same basis (confidence and severity are independent axes).

5. Every non-"accept as-is" verdict (A, B, D) in the response includes
   the required one-line reason, and no verdict silently drops a
   finding without stating one.
