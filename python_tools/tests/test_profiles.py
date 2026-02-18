import pytest
from pydantic import ValidationError

from watering.profiles import CropProfile


class TestCropProfile:
    def test_valid_crop_profile(self):
        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=28.5,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )
        assert profile.crop_id == "tomato"
        assert profile.crop_name == "Tomato"
        assert profile.dry_threshold == 28.5
        assert profile.runtime_seconds == 45
        assert profile.max_daily_runtime_seconds == 300

    def test_crop_profile_empty_crop_id_fails(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )
        assert "crop_id" in str(exc.value)

    def test_crop_profile_empty_crop_name_fails(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="tomato",
                crop_name="",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )
        assert "crop_name" in str(exc.value)

    def test_crop_profile_dry_threshold_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=-0.1,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=100.1,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )

    def test_crop_profile_runtime_seconds_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=-1,
                max_daily_runtime_seconds=300,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=3601,
                max_daily_runtime_seconds=300,
            )

    def test_crop_profile_max_daily_runtime_out_of_range(self):
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=-1,
            )
        with pytest.raises(ValidationError):
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=3601,
            )

    def test_crop_profile_extra_field_forbidden(self):
        with pytest.raises(ValidationError) as exc:
            CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
                extra_field="not_allowed",
            )
        assert "extra_field" in str(exc.value).lower()

    def test_crop_profile_boundary_values_dry_threshold(self):
        # Test exact boundaries for dry_threshold
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=0.0,
            runtime_seconds=10,
            max_daily_runtime_seconds=100,
        )
        assert profile.dry_threshold == 0.0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=100.0,
            runtime_seconds=10,
            max_daily_runtime_seconds=100,
        )
        assert profile.dry_threshold == 100.0

    def test_crop_profile_boundary_values_runtime(self):
        # Test exact boundaries for runtime_seconds
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=0,
            max_daily_runtime_seconds=100,
        )
        assert profile.runtime_seconds == 0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=3600,
            max_daily_runtime_seconds=3600,
        )
        assert profile.runtime_seconds == 3600

    def test_crop_profile_boundary_values_max_daily_runtime(self):
        # Test exact boundaries for max_daily_runtime_seconds
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=0,
            max_daily_runtime_seconds=0,
        )
        assert profile.max_daily_runtime_seconds == 0

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=100,
            max_daily_runtime_seconds=3600,
        )
        assert profile.max_daily_runtime_seconds == 3600

    def test_crop_profile_realistic_values(self):
        # Test some realistic crop profiles
        tomato = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )
        assert tomato.runtime_seconds <= tomato.max_daily_runtime_seconds

        basil = CropProfile(
            crop_id="basil",
            crop_name="Basil",
            dry_threshold=35.0,
            runtime_seconds=30,
            max_daily_runtime_seconds=240,
        )
        assert basil.runtime_seconds <= basil.max_daily_runtime_seconds

    def test_crop_profile_serialization(self):
        profile = CropProfile(
            crop_id="lettuce",
            crop_name="Lettuce",
            dry_threshold=40.0,
            runtime_seconds=60,
            max_daily_runtime_seconds=360,
        )
        # Test model_dump
        data = profile.model_dump()
        assert data["crop_id"] == "lettuce"
        assert data["crop_name"] == "Lettuce"
        assert data["dry_threshold"] == 40.0
        assert data["runtime_seconds"] == 60
        assert data["max_daily_runtime_seconds"] == 360

    def test_crop_profile_deserialization(self):
        data = {
            "crop_id": "pepper",
            "crop_name": "Bell Pepper",
            "dry_threshold": 32.0,
            "runtime_seconds": 50,
            "max_daily_runtime_seconds": 400,
        }
        profile = CropProfile.model_validate(data)
        assert profile.crop_id == "pepper"
        assert profile.crop_name == "Bell Pepper"
        assert profile.dry_threshold == 32.0
        assert profile.runtime_seconds == 50
        assert profile.max_daily_runtime_seconds == 400

    def test_crop_profile_runtime_exceeds_max_daily_allowed(self):
        # This is logically odd but not invalid per schema
        # (runtime per watering > max daily is technically allowed by field constraints)
        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=300,
            max_daily_runtime_seconds=100,
        )
        # Should not raise - the schema allows this, decision logic will clamp
        assert profile.runtime_seconds == 300
        assert profile.max_daily_runtime_seconds == 100
