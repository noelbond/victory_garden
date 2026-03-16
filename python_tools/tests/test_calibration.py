import pytest
from pydantic import ValidationError

from watering.calibration import CalibrationProfile, raw_to_percent


class TestCalibrationProfile:
    def test_valid_calibration_profile(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        assert profile.raw_dry == 3000
        assert profile.raw_wet == 1200

    def test_calibration_profile_raw_dry_out_of_range(self):
        with pytest.raises(ValidationError):
            CalibrationProfile(raw_dry=-1, raw_wet=1200)
        with pytest.raises(ValidationError):
            CalibrationProfile(raw_dry=65536, raw_wet=1200)

    def test_calibration_profile_raw_wet_out_of_range(self):
        with pytest.raises(ValidationError):
            CalibrationProfile(raw_dry=3000, raw_wet=-1)
        with pytest.raises(ValidationError):
            CalibrationProfile(raw_dry=3000, raw_wet=65536)

    def test_calibration_profile_extra_field_forbidden(self):
        with pytest.raises(ValidationError):
            CalibrationProfile(raw_dry=3000, raw_wet=1200, extra_field="not_allowed")

    def test_calibration_profile_boundary_values(self):
        profile = CalibrationProfile(raw_dry=0, raw_wet=0)
        assert profile.raw_dry == 0
        assert profile.raw_wet == 0

        profile = CalibrationProfile(raw_dry=65535, raw_wet=65535)
        assert profile.raw_dry == 65535
        assert profile.raw_wet == 65535

    def test_calibration_profile_same_values(self):
        profile = CalibrationProfile(raw_dry=2000, raw_wet=2000)
        assert profile.raw_dry == 2000
        assert profile.raw_wet == 2000

    def test_calibration_profile_serialization(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        data = profile.model_dump()
        assert data["raw_dry"] == 3000
        assert data["raw_wet"] == 1200

    def test_calibration_profile_deserialization(self):
        data = {"raw_dry": 2800, "raw_wet": 1100}
        profile = CalibrationProfile.model_validate(data)
        assert profile.raw_dry == 2800
        assert profile.raw_wet == 1100


class TestRawToPercent:
    def test_raw_to_percent_typical_case(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        assert raw_to_percent(1200, profile) == pytest.approx(100.0)
        assert raw_to_percent(3000, profile) == pytest.approx(0.0)
        assert raw_to_percent(2100, profile) == pytest.approx(50.0)

    def test_raw_to_percent_quarter_points(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1000)
        assert raw_to_percent(1500, profile) == pytest.approx(75.0)
        assert raw_to_percent(2500, profile) == pytest.approx(25.0)

    def test_raw_to_percent_below_wet_clamps_to_100(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        assert raw_to_percent(1000, profile) == pytest.approx(100.0)
        assert raw_to_percent(0, profile) == pytest.approx(100.0)

    def test_raw_to_percent_above_dry_clamps_to_0(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        assert raw_to_percent(3500, profile) == pytest.approx(0.0)
        assert raw_to_percent(65535, profile) == pytest.approx(0.0)

    def test_raw_to_percent_zero_range(self):
        profile = CalibrationProfile(raw_dry=2000, raw_wet=2000)
        # A degenerate calibration should not raise or divide by zero.
        assert raw_to_percent(2000, profile) == pytest.approx(0.0)
        assert raw_to_percent(1500, profile) == pytest.approx(0.0)
        assert raw_to_percent(2500, profile) == pytest.approx(0.0)

    def test_raw_to_percent_inverted_profile(self):
        # Inverted calibration points are schema-valid, so conversion still
        # needs predictable behavior.
        profile = CalibrationProfile(raw_dry=1200, raw_wet=3000)
        assert raw_to_percent(3000, profile) == pytest.approx(100.0)
        assert raw_to_percent(1200, profile) == pytest.approx(0.0)
        assert raw_to_percent(2100, profile) == pytest.approx(50.0)

    def test_raw_to_percent_realistic_sensor_values(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        assert 25 <= raw_to_percent(2550, profile) <= 30
        assert 45 <= raw_to_percent(2100, profile) <= 55
        assert 70 <= raw_to_percent(1740, profile) <= 80

    def test_raw_to_percent_precision(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1000)
        result = raw_to_percent(2000, profile)
        assert isinstance(result, float)
        assert result == pytest.approx(50.0)

        result = raw_to_percent(1500, profile)
        assert result == pytest.approx(75.0)

    def test_raw_to_percent_edge_case_boundary_values(self):
        profile = CalibrationProfile(raw_dry=65535, raw_wet=0)
        assert raw_to_percent(0, profile) == pytest.approx(100.0)
        assert raw_to_percent(65535, profile) == pytest.approx(0.0)
        midpoint = 65535 // 2
        assert raw_to_percent(midpoint, profile) == pytest.approx(50.0, abs=1.0)

    def test_raw_to_percent_small_range(self):
        profile = CalibrationProfile(raw_dry=1005, raw_wet=1000)
        assert raw_to_percent(1000, profile) == pytest.approx(100.0)
        assert raw_to_percent(1005, profile) == pytest.approx(0.0)
        assert 40 <= raw_to_percent(1002, profile) <= 60

    def test_raw_to_percent_returns_clamped_values(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        for raw in range(0, 4000, 100):
            percent = raw_to_percent(raw, profile)
            assert 0.0 <= percent <= 100.0

    def test_raw_to_percent_linear_interpolation(self):
        profile = CalibrationProfile(raw_dry=2000, raw_wet=1000)
        test_points = [
            (1000, 100.0),
            (1100, 90.0),
            (1200, 80.0),
            (1300, 70.0),
            (1400, 60.0),
            (1500, 50.0),
            (1600, 40.0),
            (1700, 30.0),
            (1800, 20.0),
            (1900, 10.0),
            (2000, 0.0),
        ]

        for raw, expected_percent in test_points:
            assert raw_to_percent(raw, profile) == pytest.approx(expected_percent)
