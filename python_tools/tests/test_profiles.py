import pytest
from pydantic import ValidationError

from watering.profiles import CropProfile


class TestCropProfile:
    def test_valid_crop_profile(self):
        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=28.5,
            max_pulse_runtime_sec=45,
            daily_max_runtime_sec=300,
            climate_preference="Warm, sunny",
            time_to_harvest_days=75,
        )
        assert profile.crop_id == "tomato"
        assert profile.crop_name == "Tomato"
        assert profile.dry_threshold == 28.5
        assert profile.max_pulse_runtime_sec == 45
        assert profile.daily_max_runtime_sec == 300
        assert profile.climate_preference == "Warm, sunny"
        assert profile.time_to_harvest_days == 75

    def test_crop_profile_empty_crop_id_fails(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=300,
            )
        assert "crop_id" in str(exc.value)

    def test_crop_profile_empty_crop_name_fails(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="tomato",
                crop_name="",
                dry_threshold=30.0,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=300,
            )
        assert "crop_name" in str(exc.value)

    def test_crop_profile_dry_threshold_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=-0.1,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=300,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=100.1,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=300,
            )

    def test_crop_profile_runtime_seconds_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=-1,
                daily_max_runtime_sec=300,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=3601,
                daily_max_runtime_sec=300,
            )

    def test_crop_profile_max_daily_runtime_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=-1,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=3601,
            )

    def test_crop_profile_extra_field_forbidden(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                max_pulse_runtime_sec=45,
                daily_max_runtime_sec=300,
                extra_field="not_allowed",
            )
        assert "extra_field" in str(exc.value).lower()

    def test_crop_profile_boundary_values_dry_threshold(self):
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=0.0,
            max_pulse_runtime_sec=10,
            daily_max_runtime_sec=100,
        )
        assert profile.dry_threshold == 0.0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=100.0,
            max_pulse_runtime_sec=10,
            daily_max_runtime_sec=100,
        )
        assert profile.dry_threshold == 100.0

    def test_crop_profile_boundary_values_runtime(self):
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            max_pulse_runtime_sec=0,
            daily_max_runtime_sec=100,
        )
        assert profile.runtime_seconds == 0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            max_pulse_runtime_sec=3600,
            daily_max_runtime_sec=3600,
        )
        assert profile.runtime_seconds == 3600

    def test_crop_profile_boundary_values_max_daily_runtime(self):
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            max_pulse_runtime_sec=0,
            daily_max_runtime_sec=0,
        )
        assert profile.max_daily_runtime_seconds == 0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            max_pulse_runtime_sec=100,
            daily_max_runtime_sec=3600,
        )
        assert profile.max_daily_runtime_seconds == 3600

    def test_crop_profile_realistic_values(self):
        tomato = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            max_pulse_runtime_sec=45,
            daily_max_runtime_sec=300,
        )
        assert tomato.runtime_seconds <= tomato.max_daily_runtime_seconds

        basil = CropProfile(
            crop_id="basil",
            crop_name="Basil",
            dry_threshold=40.0,
            max_pulse_runtime_sec=30,
            daily_max_runtime_sec=240,
        )
        assert basil.runtime_seconds <= basil.max_daily_runtime_seconds

    def test_crop_profile_serialization(self):
        profile = CropProfile(
            crop_id="lettuce",
            crop_name="Lettuce",
            dry_threshold=40.0,
            max_pulse_runtime_sec=60,
            daily_max_runtime_sec=360,
            climate_preference="Cool, partial shade",
            time_to_harvest_days=55,
        )
        data = profile.model_dump()
        assert data["crop_id"] == "lettuce"
        assert data["crop_name"] == "Lettuce"
        assert data["dry_threshold"] == 40.0
        assert data["max_pulse_runtime_sec"] == 60
        assert data["daily_max_runtime_sec"] == 360
        assert data["climate_preference"] == "Cool, partial shade"
        assert data["time_to_harvest_days"] == 55

    def test_crop_profile_deserialization(self):
        data = {
            "crop_id": "pepper",
            "crop_name": "Bell Pepper",
            "dry_threshold": 32.0,
            "max_pulse_runtime_sec": 50,
            "daily_max_runtime_sec": 400,
            "climate_preference": "Warm, sunny",
            "time_to_harvest_days": 80,
        }
        profile = CropProfile.model_validate(data)
        assert profile.crop_id == "pepper"
        assert profile.crop_name == "Bell Pepper"
        assert profile.dry_threshold == 32.0
        assert profile.max_pulse_runtime_sec == 50
        assert profile.daily_max_runtime_sec == 400
        assert profile.climate_preference == "Warm, sunny"
        assert profile.time_to_harvest_days == 80

    def test_crop_profile_runtime_exceeds_max_daily_allowed(self):
        # The schema allows this shape, and decision logic clamps it later.
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            max_pulse_runtime_sec=300,
            daily_max_runtime_sec=100,
        )
        assert profile.runtime_seconds == 300
        assert profile.max_daily_runtime_seconds == 100
