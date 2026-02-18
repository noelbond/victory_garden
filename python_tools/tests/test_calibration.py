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
        # Same values are allowed by schema (though they'd produce degenerate results)
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
        # Dry=3000, Wet=1200, Range=1800
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        # At wet point (1200) should be 100%
        assert raw_to_percent(1200, profile) == pytest.approx(100.0)

        # At dry point (3000) should be 0%
        assert raw_to_percent(3000, profile) == pytest.approx(0.0)

        # Midpoint (2100) should be 50%
        assert raw_to_percent(2100, profile) == pytest.approx(50.0)

    def test_raw_to_percent_quarter_points(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1000)
        # Range = 2000

        # 75% wet: 1000 + 0.25*2000 = 1500
        assert raw_to_percent(1500, profile) == pytest.approx(75.0)

        # 25% wet: 1000 + 0.75*2000 = 2500
        assert raw_to_percent(2500, profile) == pytest.approx(25.0)

    def test_raw_to_percent_below_wet_clamps_to_100(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        # Below wet point should clamp to 100%
        assert raw_to_percent(1000, profile) == pytest.approx(100.0)
        assert raw_to_percent(0, profile) == pytest.approx(100.0)

    def test_raw_to_percent_above_dry_clamps_to_0(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        # Above dry point should clamp to 0%
        assert raw_to_percent(3500, profile) == pytest.approx(0.0)
        assert raw_to_percent(65535, profile) == pytest.approx(0.0)

    def test_raw_to_percent_zero_range(self):
        # When dry == wet, division by zero case
        profile = CalibrationProfile(raw_dry=2000, raw_wet=2000)

        # Should return 0.0 to avoid division by zero
        assert raw_to_percent(2000, profile) == pytest.approx(0.0)
        assert raw_to_percent(1500, profile) == pytest.approx(0.0)
        assert raw_to_percent(2500, profile) == pytest.approx(0.0)

    def test_raw_to_percent_inverted_profile(self):
        # If raw_wet > raw_dry (inverted), the math still works
        # but produces negative percentages that get clamped
        profile = CalibrationProfile(raw_dry=1200, raw_wet=3000)

        # At "wet" (3000): (1200 - 3000) / (1200 - 3000) * 100 = 100%
        assert raw_to_percent(3000, profile) == pytest.approx(100.0)

        # At "dry" (1200): (1200 - 1200) / (1200 - 3000) * 100 = 0%
        assert raw_to_percent(1200, profile) == pytest.approx(0.0)

        # Midpoint (2100): (1200 - 2100) / (1200 - 3000) * 100 = 50%
        assert raw_to_percent(2100, profile) == pytest.approx(50.0)

    def test_raw_to_percent_realistic_sensor_values(self):
        # Realistic capacitive soil moisture sensor values
        # Dry in air: ~3000, Wet in water: ~1200
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        # Moderately dry soil
        assert 25 <= raw_to_percent(2550, profile) <= 30

        # Medium moisture
        assert 45 <= raw_to_percent(2100, profile) <= 55

        # Wet soil
        assert 70 <= raw_to_percent(1740, profile) <= 80

    def test_raw_to_percent_precision(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1000)

        # Test that we get precise floating point results
        result = raw_to_percent(2000, profile)
        assert isinstance(result, float)
        assert result == pytest.approx(50.0)

        result = raw_to_percent(1500, profile)
        assert result == pytest.approx(75.0)

    def test_raw_to_percent_edge_case_boundary_values(self):
        profile = CalibrationProfile(raw_dry=65535, raw_wet=0)

        # At extreme wet (0)
        assert raw_to_percent(0, profile) == pytest.approx(100.0)

        # At extreme dry (65535)
        assert raw_to_percent(65535, profile) == pytest.approx(0.0)

        # Midpoint
        midpoint = 65535 // 2
        assert raw_to_percent(midpoint, profile) == pytest.approx(50.0, abs=1.0)

    def test_raw_to_percent_small_range(self):
        # Very small calibration range
        profile = CalibrationProfile(raw_dry=1005, raw_wet=1000)

        assert raw_to_percent(1000, profile) == pytest.approx(100.0)
        assert raw_to_percent(1005, profile) == pytest.approx(0.0)
        # Midpoint at 1002.5, so 1002 or 1003
        assert 40 <= raw_to_percent(1002, profile) <= 60

    def test_raw_to_percent_returns_clamped_values(self):
        profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        # Test many values to ensure all are in [0, 100]
        for raw in range(0, 4000, 100):
            percent = raw_to_percent(raw, profile)
            assert 0.0 <= percent <= 100.0

    def test_raw_to_percent_linear_interpolation(self):
        # Verify linear behavior across range
        profile = CalibrationProfile(raw_dry=2000, raw_wet=1000)

        # Test points along the range
        test_points = [
            (1000, 100.0),  # Wet
            (1100, 90.0),
            (1200, 80.0),
            (1300, 70.0),
            (1400, 60.0),
            (1500, 50.0),
            (1600, 40.0),
            (1700, 30.0),
            (1800, 20.0),
            (1900, 10.0),
            (2000, 0.0),  # Dry
        ]

        for raw, expected_percent in test_points:
            assert raw_to_percent(raw, profile) == pytest.approx(expected_percent)
