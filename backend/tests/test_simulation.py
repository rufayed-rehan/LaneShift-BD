from __future__ import annotations

from dataclasses import replace

import pytest

from backend.app.simulation import (
    ScenarioConfig,
    SegmentConfig,
    evaluate_all_candidates,
    generate_demand,
    simulate_candidate,
)


@pytest.fixture(scope="module")
def segment() -> SegmentConfig:
    return SegmentConfig(
        segment_id=1,
        segment_code="AIR-01",
        name="Airport to Khilkhet",
        total_lanes=6,
        baseline_inbound_lanes=3,
        baseline_outbound_lanes=3,
        capacity_per_lane=1800,
        speed_limit_kph=60.0,
    )


@pytest.fixture(scope="module")
def balanced() -> ScenarioConfig:
    return ScenarioConfig(
        scenario_id=1,
        scenario_code="balanced",
        name="Balanced traffic",
        inbound_rate_vph=2100,
        outbound_rate_vph=2000,
        inbound_surge_multiplier=1.0,
        outbound_surge_multiplier=1.0,
        surge_start_minute=None,
        incident_direction=None,
        incident_start_minute=None,
        incident_capacity_factor=1.0,
        weather_speed_factor=1.0,
        duration_minutes=60,
    )


@pytest.fixture(scope="module")
def morning_peak(balanced: ScenarioConfig) -> ScenarioConfig:
    return replace(
        balanced,
        scenario_id=2,
        scenario_code="morning_peak",
        name="Morning inbound surge",
        inbound_rate_vph=4700,
        outbound_rate_vph=1450,
        inbound_surge_multiplier=1.28,
        surge_start_minute=20,
    )


def test_same_seed_produces_the_same_demand(morning_peak: ScenarioConfig) -> None:
    first = generate_demand(morning_peak, seed=4410)
    second = generate_demand(morning_peak, seed=4410)
    different = generate_demand(morning_peak, seed=4411)

    assert first == second
    assert first != different
    assert len(first) > 5000


def test_every_safe_lane_split_is_evaluated(
    segment: SegmentConfig,
    balanced: ScenarioConfig,
) -> None:
    results = evaluate_all_candidates(segment=segment, scenario=balanced, seed=4410)

    assert len(results) == segment.total_lanes - 1
    assert {(item.inbound_lanes, item.outbound_lanes) for item in results} == {
        (1, 5),
        (2, 4),
        (3, 3),
        (4, 2),
        (5, 1),
    }
    assert sum(item.is_baseline for item in results) == 1
    assert all(item.inbound_lanes + item.outbound_lanes == 6 for item in results)


def test_balanced_traffic_prefers_the_baseline(
    segment: SegmentConfig,
    balanced: ScenarioConfig,
) -> None:
    results = evaluate_all_candidates(segment=segment, scenario=balanced, seed=4410)
    winner = min(results, key=lambda item: item.objective_score)

    assert (winner.inbound_lanes, winner.outbound_lanes) == (3, 3)
    assert winner.average_wait_seconds < 1.0


def test_morning_pressure_benefits_from_more_inbound_lanes(
    segment: SegmentConfig,
    morning_peak: ScenarioConfig,
) -> None:
    results = evaluate_all_candidates(segment=segment, scenario=morning_peak, seed=4410)
    baseline = next(item for item in results if item.is_baseline)
    winner = min(results, key=lambda item: item.objective_score)

    assert winner.inbound_lanes > segment.baseline_inbound_lanes
    assert winner.average_wait_seconds < baseline.average_wait_seconds
    assert winner.max_queue_vehicles < baseline.max_queue_vehicles


def test_incident_increases_baseline_congestion(
    segment: SegmentConfig,
    balanced: ScenarioConfig,
) -> None:
    accident = replace(
        balanced,
        scenario_code="inbound_accident",
        inbound_rate_vph=3900,
        outbound_rate_vph=1500,
        inbound_surge_multiplier=1.10,
        surge_start_minute=15,
        incident_direction="inbound",
        incident_start_minute=20,
        incident_capacity_factor=0.48,
        weather_speed_factor=0.82,
    )
    calm_demand = generate_demand(balanced, 4410)
    accident_demand = generate_demand(accident, 4410)
    calm = simulate_candidate(
        segment=segment,
        scenario=balanced,
        demand=calm_demand,
        inbound_lanes=3,
        outbound_lanes=3,
    )
    disrupted = simulate_candidate(
        segment=segment,
        scenario=accident,
        demand=accident_demand,
        inbound_lanes=3,
        outbound_lanes=3,
    )

    assert disrupted.max_queue_vehicles > calm.max_queue_vehicles
    assert disrupted.average_wait_seconds > calm.average_wait_seconds


@pytest.mark.parametrize("inbound,outbound", [(0, 6), (6, 0), (4, 3)])
def test_unsafe_lane_splits_are_rejected(
    segment: SegmentConfig,
    balanced: ScenarioConfig,
    inbound: int,
    outbound: int,
) -> None:
    with pytest.raises(ValueError):
        simulate_candidate(
            segment=segment,
            scenario=balanced,
            demand=(),
            inbound_lanes=inbound,
            outbound_lanes=outbound,
        )
