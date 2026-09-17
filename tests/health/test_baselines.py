"""Baselines are medians of your own days, and must survive midnight."""
from jarvis_health.baselines import baseline_from, bedtime_minute, bedtime_minute_median, resting_hr

from .fixtures import day, series


def test_baseline_takes_medians_over_the_window_and_counts_days():
    b = baseline_from([day(hrv=40), day(hrv=44), day(hrv=48), day(hrv=60)], window=14)
    assert b.hrv == 46
    assert b.days_used == 4
    assert b.is_ready is True


def test_the_window_bounds_how_far_back_a_baseline_looks():
    days = [day(hrv=40) for _ in range(20)]
    assert baseline_from(days, window=14).days_used == 14


def test_resting_hr_is_the_lowest_ten_minute_mean_of_the_night():
    # Five-minute samples, so ten contiguous minutes is three of them:
    # 56, 56, 58 is the quietest stretch the night contains.
    night = day(hr=[0] * 12 + [70] * 6 + [56] * 2 + [58] * 2 + [80] * 20)
    assert resting_hr(night) == 56.7


def test_one_low_sample_is_noise_and_does_not_become_your_resting_rate():
    night = day(hr=[0] * 12 + [70] * 6 + [44] + [70] * 20)
    # The dip is averaged across the window it sits in; it never stands alone.
    assert resting_hr(night) == 61.3


def test_resting_hr_needs_a_night_and_a_series():
    assert resting_hr(day(asleep=0)) is None
    assert resting_hr(day(hr=[])) is None


def test_bedtime_median_wraps_across_midnight():
    assert bedtime_minute_median([1410, 30, 1425]) == 1425
    assert bedtime_minute_median([]) is None


def test_bedtime_comes_from_the_night_in_local_minutes():
    assert bedtime_minute(day(bedtime_minute=1410)) == 1410


def test_a_lone_reading_is_never_a_resting_rate_on_its_own():
    """The window is ten contiguous minutes, not ten adjacent list entries.

    The 45 at 01:00 has no neighbours, so no ten-minute window contains it and
    it is ignored. The 45 at 03:00 does sit inside a real window — with two 70s
    — so it counts for what it is, averaged, rather than as a 45 bpm low.
    """
    values = [0] * 96
    values[12] = 45          # 01:00, alone between zeros
    values[36] = 45          # 03:00, followed by real readings
    for i in range(37, 84):
        values[i] = 70
    assert resting_hr(day(hr=values)) == 61.7


def test_a_night_the_device_sent_without_a_start_is_not_a_crash():
    from jarvis_health.metrics import STAGE_LIGHT, HealthDay, SleepSession

    broken = HealthDay(
        date="2026-09-17", timezone="America/Chicago", utc_offset=-18000,
        sleep=[SleepSession(start="", end="", stages=[(STAGE_LIGHT, 420)])],
        heart_rate=series([60] * 100),
    )
    assert resting_hr(broken) is None
    assert baseline_from([broken]).resting_hr is None
