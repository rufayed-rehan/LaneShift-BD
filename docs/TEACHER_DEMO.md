# LaneShift BD — Classroom Demonstration Guide

## One-sentence project definition

LaneShift BD is a database-centered traffic digital twin that uses SimPy to test reversible-lane arrangements and PostgreSQL to validate, select, and audit the best qualified decision.

## Before class

1. Start PostgreSQL.
2. Open the `LaneShift-BD` folder in VS Code.
3. Open the VS Code Terminal.
4. Optionally run `./scripts/reset_database_mac.sh` for an empty run history.
5. Run `./scripts/test_all_mac.sh` and confirm all checks pass.
6. Run `./scripts/start_all_mac.sh`.
7. Open <http://127.0.0.1:5173>.
8. Keep <http://127.0.0.1:8000/docs> open in a second browser tab.

## Five-minute demonstration

### 1. Explain the revised problem — 30 seconds

> The earlier version calculated a lane split directly from vehicle-count ratios and mainly waited for operator approval. The revised system asks a measurable question: can a simulated and automatically selected allocation reduce queueing compared with fixed lanes?

### 2. Explain the architecture — 40 seconds

> PostgreSQL stores the road, scenario, run, candidate, sample, decision, and audit data. SimPy is a computational worker: it generates stochastic vehicles and measures every safe allocation. PostgreSQL then applies the business rules and selects a winner only when the improvement exceeds the configured threshold. React visualizes the stored results.

Emphasize: **SimPy generates; PostgreSQL decides; React explains.**

### 3. Run the experiment — 60 seconds

In **Simulation lab** select:

- Scenario: **Morning inbound surge**
- Segment: **AIR-01 — Airport to Khilkhet — 6 lanes**
- Random seed: **4410**

Click **Run automated experiment**.

Explain:

> Seed 4410 makes the random arrival stream reproducible. The same vehicles are replayed for 1/5, 2/4, 3/3, 4/2, and 5/1, so the comparison is fair.

### 4. Explain the result — 60 seconds

Point to:

- Fixed `3/3` allocation
- Selected `4/2` allocation
- Percentage objective improvement
- Waiting time
- Maximum queue
- Average speed
- Completed vehicles

> PostgreSQL does not select the lowest raw formula. It receives measured results from all counterfactual simulations, ranks their objective scores, applies the 10% improvement requirement, and records one selected candidate.

### 5. Show database evidence — 70 seconds

Scroll through:

- The fixed-versus-selected queue chart
- The table containing every candidate
- The automated audit timeline

Open **Run history** to show persistence. Then open **DBMS evidence** and point out:

- Tables and foreign keys
- Views
- Functions and procedures
- Triggers
- Indexes
- Row counts
- Safety rules that the Python layer cannot bypass

### 6. Explain human oversight — 20 seconds

> Automation is applied only inside the educational simulation. In a real road deployment, the same decision would enter advisory mode and require safety confirmation. The operator is an emergency override, not the person calculating routine allocations.

## Main database concepts to mention

- Normalized relational design
- Time-series and experiment data
- Primary and foreign keys
- Check and unique constraints
- Partial unique indexes
- Range types and GiST exclusion constraints
- Triggers and status transitions
- Stored functions and procedures
- Transactions
- Window functions and analytical views
- JSONB audit details
- Reproducible experiment history

## Questions the teacher may ask

### Why is this a DBMS project instead of only a Python simulation?

Python has no authority to apply a result. PostgreSQL owns the persistent experiment state, validates all candidates, prevents invalid or conflicting decisions, chooses whether the improvement threshold is satisfied, and stores the audit history. The Python worker can be restarted without losing the system state.

### Why use SimPy?

It is a discrete-event simulation library. Each vehicle is a process, each direction has limited lane resources, and queues emerge when stochastic arrivals exceed effective capacity. This replaces the previous fixed traffic formula.

### Why test every candidate with the same demand?

If each allocation received different random vehicles, the comparison would be biased. A fixed seed creates one demand stream that is replayed unchanged for every allocation.

### What does the objective score contain?

It combines average wait, P95 wait, maximum queue, unfinished vehicles, and a small lane-switching stability penalty. Lower is better. Individual metrics remain visible so the decision is explainable.

### Why require at least 10% improvement?

Small simulated differences may come from random variation and do not justify reversing a lane. The threshold reduces unnecessary switching and is stored in `app_settings` rather than hardcoded in the interface.

### Does it automatically reverse a real Dhaka road?

No. This is an educational digital twin. Simulation mode applies decisions automatically inside the virtual environment. A real deployment would require physical safety systems, verified sensors, legal authority, and human confirmation.

### What happens with balanced traffic?

Run **Balanced traffic**. The switching penalty and improvement threshold should keep the normal `3/3` allocation because another arrangement does not provide a meaningful benefit.

### How is an invalid `5/2` allocation prevented on a six-lane road?

Both Python validation and a PostgreSQL trigger reject it. The database rule is authoritative even if a faulty client bypasses the frontend.

### How do you prove the result is not hardcoded?

Change the scenario or seed, run it again, and show that measurements change. Reuse seed 4410 and show that the result is reproducible. Run history keeps both experiments.

## Safe final statement

> LaneShift BD does not claim that simulation alone is enough for a real road. Its contribution is a reproducible, database-governed workflow for generating traffic pressure, comparing counterfactual lane arrangements, enforcing decision rules, and auditing the outcome.
