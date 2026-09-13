# Technical Design

## Core experiment

For each run, the system loads one road segment and one scenario from PostgreSQL. SimPy creates a stochastic demand stream using exponentially distributed inter-arrival times. Vehicle service demand varies by a fixed set of vehicle factors, representing a mixture of smaller and larger vehicles.

The generated demand is immutable for the run. Every valid inbound lane count from `1` to `total_lanes - 1` is simulated against that same demand. This is a counterfactual experiment: only the lane allocation changes.

## Queue model

Each direction uses a SimPy `Resource` whose capacity is its allocated lane count. Effective per-lane service capacity comes from `road_segments.capacity_per_lane` and is modified by:

- vehicle service factor
- scenario weather factor
- incident direction, start time, and capacity factor

Queue length is sampled every five virtual minutes. The engine records average wait, P95 wait, maximum queue, completed vehicles, unfinished vehicles, estimated speed, and throughput.

## Congestion objective

The objective is intentionally explainable:

```text
average wait
+ 0.22 × P95 wait
+ 1.35 × maximum queue
+ 1.80 × unfinished vehicles
+ 12.00 × number of lanes moved from baseline
```

Lower is better. The last term discourages unnecessary lane changes. The raw metrics and objective are stored together so reviewers do not need to trust a hidden score.

## Database finalization

`finalize_simulation_run(run_id)` locks the run, requires the `running` state, verifies that all `total_lanes - 1` candidates exist, calculates each candidate's improvement against baseline, and identifies the minimum objective.

The function selects the alternative only when its improvement satisfies `app_settings.minimum_simulation_improvement_percent`. Otherwise it retains the baseline. It then:

1. Marks exactly one candidate selected.
2. Inserts one `automation_decisions` row.
3. Inserts an audit event with baseline, selected candidate, threshold, and improvement.
4. Transitions the run to `completed`.

Candidate inserts and finalization occur in one application transaction. If any candidate or sample is invalid, the entire result set rolls back and the run is marked failed separately.

## Integrity controls

- Run baselines must equal the road's total lane count.
- Candidate and decision splits must equal the road's total lane count.
- Inbound and outbound allocations must both be positive.
- Candidate decisions must reference the same run.
- One partial unique index permits only one baseline per run.
- Another partial unique index permits only one selected candidate per run.
- Run-state triggers reject illegal transitions.
- Existing GiST exclusion rules reject overlapping physical schedules.
- Override status requires operator, reason, and timestamp fields.

## Main simulation relations

```text
traffic_scenarios
        │
        └── simulation_runs ── road_segments
                  │
                  ├── simulation_candidates
                  │          │
                  │          └── simulation_samples
                  │
                  ├── automation_decisions ── selected candidate
                  │
                  └── automation_events
```

## API lifecycle

`POST /api/simulation/runs` performs the following orchestration:

1. Validate the request with Pydantic.
2. Load the scenario and road from PostgreSQL.
3. Insert the queued run.
4. Transition it to running.
5. Generate demand and evaluate candidates with pure Python/SimPy.
6. Persist candidates and samples transactionally.
7. Invoke the PostgreSQL finalizer.
8. Return the database-backed run view with candidate, sample, and event data.

The simulation engine is kept free of database code so it can be unit-tested deterministically.
