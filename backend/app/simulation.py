from __future__ import annotations

from dataclasses import asdict, dataclass
from math import ceil
from random import Random
from statistics import mean
from typing import Any, Iterable

import simpy


@dataclass(frozen=True)
class SegmentConfig:
    segment_id: int
    segment_code: str
    name: str
    total_lanes: int
    baseline_inbound_lanes: int
    baseline_outbound_lanes: int
    capacity_per_lane: int
    speed_limit_kph: float

    @classmethod
    def from_record(cls, record: dict[str, Any]) -> "SegmentConfig":
        return cls(
            segment_id=int(record["segment_id"]),
            segment_code=str(record["segment_code"]),
            name=str(record["name"]),
            total_lanes=int(record["total_lanes"]),
            baseline_inbound_lanes=int(record["base_inbound_lanes"]),
            baseline_outbound_lanes=int(record["base_outbound_lanes"]),
            capacity_per_lane=int(record["capacity_per_lane"]),
            speed_limit_kph=float(record["speed_limit_kph"]),
        )


@dataclass(frozen=True)
class ScenarioConfig:
    scenario_id: int
    scenario_code: str
    name: str
    inbound_rate_vph: int
    outbound_rate_vph: int
    inbound_surge_multiplier: float
    outbound_surge_multiplier: float
    surge_start_minute: int | None
    incident_direction: str | None
    incident_start_minute: int | None
    incident_capacity_factor: float
    weather_speed_factor: float
    duration_minutes: int

    @classmethod
    def from_record(cls, record: dict[str, Any]) -> "ScenarioConfig":
        return cls(
            scenario_id=int(record["scenario_id"]),
            scenario_code=str(record["scenario_code"]),
            name=str(record["name"]),
            inbound_rate_vph=int(record["inbound_rate_vph"]),
            outbound_rate_vph=int(record["outbound_rate_vph"]),
            inbound_surge_multiplier=float(record["inbound_surge_multiplier"]),
            outbound_surge_multiplier=float(record["outbound_surge_multiplier"]),
            surge_start_minute=(
                int(record["surge_start_minute"])
                if record.get("surge_start_minute") is not None
                else None
            ),
            incident_direction=(
                str(record["incident_direction"])
                if record.get("incident_direction") is not None
                else None
            ),
            incident_start_minute=(
                int(record["incident_start_minute"])
                if record.get("incident_start_minute") is not None
                else None
            ),
            incident_capacity_factor=float(record["incident_capacity_factor"]),
            weather_speed_factor=float(record["weather_speed_factor"]),
            duration_minutes=int(record["duration_minutes"]),
        )


@dataclass(frozen=True)
class DemandVehicle:
    vehicle_number: int
    direction: str
    arrival_minute: float
    service_factor: float


@dataclass(frozen=True)
class SimulationSample:
    simulated_minute: int
    inbound_queue: int
    outbound_queue: int
    cumulative_completed: int
    inbound_average_wait_seconds: float
    outbound_average_wait_seconds: float
    inbound_speed_kph: float
    outbound_speed_kph: float


@dataclass(frozen=True)
class CandidateResult:
    inbound_lanes: int
    outbound_lanes: int
    is_baseline: bool
    average_wait_seconds: float
    p95_wait_seconds: float
    max_queue_vehicles: int
    completed_vehicles: int
    unprocessed_vehicles: int
    average_speed_kph: float
    throughput_vph: float
    objective_score: float
    samples: tuple[SimulationSample, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


VEHICLE_SERVICE_FACTORS = (0.82, 0.90, 0.96, 1.00, 1.08, 1.20, 1.34)


def _arrival_phases(
    base_rate_vph: int,
    surge_multiplier: float,
    surge_start_minute: int | None,
    duration_minutes: int,
) -> list[tuple[float, float, float]]:
    if surge_start_minute is None or surge_start_minute >= duration_minutes:
        return [(0.0, float(duration_minutes), float(base_rate_vph))]
    return [
        (0.0, float(surge_start_minute), float(base_rate_vph)),
        (
            float(surge_start_minute),
            float(duration_minutes),
            float(base_rate_vph) * surge_multiplier,
        ),
    ]


def _generate_direction_demand(
    *,
    direction: str,
    base_rate_vph: int,
    surge_multiplier: float,
    surge_start_minute: int | None,
    duration_minutes: int,
    randomizer: Random,
    starting_number: int,
) -> list[DemandVehicle]:
    vehicles: list[DemandVehicle] = []
    vehicle_number = starting_number
    for phase_start, phase_end, rate_vph in _arrival_phases(
        base_rate_vph,
        surge_multiplier,
        surge_start_minute,
        duration_minutes,
    ):
        if rate_vph <= 0:
            continue
        minute = phase_start
        arrivals_per_minute = rate_vph / 60.0
        while True:
            minute += randomizer.expovariate(arrivals_per_minute)
            if minute >= phase_end:
                break
            vehicles.append(
                DemandVehicle(
                    vehicle_number=vehicle_number,
                    direction=direction,
                    arrival_minute=minute,
                    service_factor=randomizer.choice(VEHICLE_SERVICE_FACTORS),
                )
            )
            vehicle_number += 1
    return vehicles


def generate_demand(scenario: ScenarioConfig, seed: int) -> tuple[DemandVehicle, ...]:
    """Create one reproducible demand stream shared by every lane candidate."""

    randomizer = Random(seed)
    inbound = _generate_direction_demand(
        direction="inbound",
        base_rate_vph=scenario.inbound_rate_vph,
        surge_multiplier=scenario.inbound_surge_multiplier,
        surge_start_minute=scenario.surge_start_minute,
        duration_minutes=scenario.duration_minutes,
        randomizer=randomizer,
        starting_number=1,
    )
    outbound = _generate_direction_demand(
        direction="outbound",
        base_rate_vph=scenario.outbound_rate_vph,
        surge_multiplier=scenario.outbound_surge_multiplier,
        surge_start_minute=scenario.surge_start_minute,
        duration_minutes=scenario.duration_minutes,
        randomizer=randomizer,
        starting_number=len(inbound) + 1,
    )
    return tuple(sorted((*inbound, *outbound), key=lambda item: item.arrival_minute))


def _percentile_95(values: Iterable[float]) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return ordered[min(len(ordered) - 1, ceil(len(ordered) * 0.95) - 1)]


def _affected_by_incident(scenario: ScenarioConfig, direction: str, minute: float) -> bool:
    return bool(
        scenario.incident_direction
        and scenario.incident_start_minute is not None
        and minute >= scenario.incident_start_minute
        and scenario.incident_direction in (direction, "both")
    )


def simulate_candidate(
    *,
    segment: SegmentConfig,
    scenario: ScenarioConfig,
    demand: tuple[DemandVehicle, ...],
    inbound_lanes: int,
    outbound_lanes: int,
    sample_interval_minutes: int = 5,
) -> CandidateResult:
    if inbound_lanes < 1 or outbound_lanes < 1:
        raise ValueError("Every direction must retain at least one lane")
    if inbound_lanes + outbound_lanes != segment.total_lanes:
        raise ValueError("Candidate lane total does not match the road segment")

    environment = simpy.Environment()
    resources = {
        "inbound": simpy.Resource(environment, capacity=inbound_lanes),
        "outbound": simpy.Resource(environment, capacity=outbound_lanes),
    }
    lane_counts = {"inbound": inbound_lanes, "outbound": outbound_lanes}
    wait_seconds: dict[str, list[float]] = {"inbound": [], "outbound": []}
    waiting_arrivals: dict[str, dict[int, float]] = {"inbound": {}, "outbound": {}}
    completed = {"inbound": 0, "outbound": 0}
    max_queue = 0
    samples: list[SimulationSample] = []

    def estimated_speed(direction: str, minute: float) -> float:
        resource = resources[direction]
        lanes = lane_counts[direction]
        congestion_factor = max(0.18, 1.0 - len(resource.queue) / max(lanes * 42.0, 1.0))
        incident_speed_factor = (
            max(0.45, scenario.incident_capacity_factor)
            if _affected_by_incident(scenario, direction, minute)
            else 1.0
        )
        return max(
            5.0,
            segment.speed_limit_kph
            * scenario.weather_speed_factor
            * incident_speed_factor
            * congestion_factor,
        )

    def vehicle_process(vehicle: DemandVehicle):
        nonlocal max_queue
        yield environment.timeout(max(0.0, vehicle.arrival_minute - environment.now))
        direction = vehicle.direction
        resource = resources[direction]
        waiting_arrivals[direction][vehicle.vehicle_number] = environment.now
        max_queue = max(max_queue, len(resources["inbound"].queue) + len(resources["outbound"].queue) + 1)

        with resource.request() as request:
            yield request
            queued_at = waiting_arrivals[direction].pop(vehicle.vehicle_number)
            wait_seconds[direction].append((environment.now - queued_at) * 60.0)

            effective_capacity_factor = scenario.weather_speed_factor
            if _affected_by_incident(scenario, direction, environment.now):
                effective_capacity_factor *= scenario.incident_capacity_factor
            effective_capacity_factor = max(effective_capacity_factor, 0.10)
            service_minutes = (
                60.0
                / segment.capacity_per_lane
                * vehicle.service_factor
                / effective_capacity_factor
            )
            yield environment.timeout(service_minutes)
            completed[direction] += 1

    def record_sample(minute: int) -> None:
        in_waits = wait_seconds["inbound"]
        out_waits = wait_seconds["outbound"]
        samples.append(
            SimulationSample(
                simulated_minute=minute,
                inbound_queue=len(resources["inbound"].queue),
                outbound_queue=len(resources["outbound"].queue),
                cumulative_completed=completed["inbound"] + completed["outbound"],
                inbound_average_wait_seconds=round(mean(in_waits), 2) if in_waits else 0.0,
                outbound_average_wait_seconds=round(mean(out_waits), 2) if out_waits else 0.0,
                inbound_speed_kph=round(estimated_speed("inbound", minute), 2),
                outbound_speed_kph=round(estimated_speed("outbound", minute), 2),
            )
        )

    def monitor():
        record_sample(0)
        next_minute = sample_interval_minutes
        while next_minute <= scenario.duration_minutes:
            yield environment.timeout(next_minute - environment.now)
            record_sample(next_minute)
            next_minute += sample_interval_minutes

    for demand_vehicle in demand:
        environment.process(vehicle_process(demand_vehicle))
    environment.process(monitor())
    environment.run(until=scenario.duration_minutes + 0.000001)

    unfinished_waits: list[float] = []
    for direction in ("inbound", "outbound"):
        unfinished_waits.extend(
            max(0.0, scenario.duration_minutes - arrival_minute) * 60.0
            for arrival_minute in waiting_arrivals[direction].values()
        )
    observed_waits = wait_seconds["inbound"] + wait_seconds["outbound"] + unfinished_waits
    average_wait = mean(observed_waits) if observed_waits else 0.0
    p95_wait = _percentile_95(observed_waits)
    completed_total = completed["inbound"] + completed["outbound"]
    unprocessed = max(0, len(demand) - completed_total)
    average_speed = mean(
        (sample.inbound_speed_kph + sample.outbound_speed_kph) / 2.0
        for sample in samples
    )
    throughput_vph = completed_total / scenario.duration_minutes * 60.0
    shifted_lanes = abs(inbound_lanes - segment.baseline_inbound_lanes)
    objective_score = (
        average_wait
        + p95_wait * 0.22
        + max_queue * 1.35
        + unprocessed * 1.80
        + shifted_lanes * 12.0
    )

    return CandidateResult(
        inbound_lanes=inbound_lanes,
        outbound_lanes=outbound_lanes,
        is_baseline=(
            inbound_lanes == segment.baseline_inbound_lanes
            and outbound_lanes == segment.baseline_outbound_lanes
        ),
        average_wait_seconds=round(average_wait, 2),
        p95_wait_seconds=round(p95_wait, 2),
        max_queue_vehicles=max(max_queue, *(s.inbound_queue + s.outbound_queue for s in samples)),
        completed_vehicles=completed_total,
        unprocessed_vehicles=unprocessed,
        average_speed_kph=round(average_speed, 2),
        throughput_vph=round(throughput_vph, 2),
        objective_score=round(objective_score, 4),
        samples=tuple(samples),
    )


def evaluate_all_candidates(
    *,
    segment: SegmentConfig,
    scenario: ScenarioConfig,
    seed: int,
    sample_interval_minutes: int = 5,
) -> tuple[CandidateResult, ...]:
    """Evaluate every safe split with one shared stochastic demand stream."""

    demand = generate_demand(scenario, seed)
    results = [
        simulate_candidate(
            segment=segment,
            scenario=scenario,
            demand=demand,
            inbound_lanes=inbound_lanes,
            outbound_lanes=segment.total_lanes - inbound_lanes,
            sample_interval_minutes=sample_interval_minutes,
        )
        for inbound_lanes in range(1, segment.total_lanes)
    ]
    return tuple(results)
