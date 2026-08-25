require "test_helper"

class LoraReceiverStatusTest < ActiveSupport::TestCase
  test "current returns parsed status when status file exists" do
    Dir.mktmpdir("vg-lora-status") do |dir|
      path = Pathname.new(File.join(dir, "lora_receiver_status.json"))
      File.write(path, JSON.generate({status: "connected", serial_connected: true, updated_at: "2026-08-25T12:00:00Z"}))

      status = LoraReceiverStatus.current(
        path: path,
        environ: {"LORA_ENABLED" => "true"},
        now: Time.iso8601("2026-08-25T12:01:00Z")
      )

      assert_equal "connected", status["status"]
      assert_equal true, status["serial_connected"]
      assert_equal true, status["enabled"]
    end
  end

  test "current returns disabled status when lora is not enabled" do
    Dir.mktmpdir("vg-lora-status") do |dir|
      missing_path = Pathname.new(File.join(dir, "missing.json"))

      assert_equal(
        {"enabled" => false, "status" => "disabled"},
        LoraReceiverStatus.current(path: missing_path, environ: {"LORA_ENABLED" => "false"})
      )
    end
  end

  test "current reports missing or invalid status when lora is enabled" do
    Dir.mktmpdir("vg-lora-status") do |dir|
      missing_path = Pathname.new(File.join(dir, "missing.json"))
      invalid_path = Pathname.new(File.join(dir, "invalid.json"))
      File.write(invalid_path, "{")

      assert_equal(
        {
          "enabled" => true,
          "status" => "missing",
          "last_error" => "LoRa receiver status file is missing"
        },
        LoraReceiverStatus.current(path: missing_path, environ: {"LORA_ENABLED" => "true"})
      )
      assert_equal(
        {
          "enabled" => true,
          "status" => "invalid",
          "last_error" => "LoRa receiver status file is invalid JSON"
        },
        LoraReceiverStatus.current(path: invalid_path, environ: {"LORA_ENABLED" => "true"})
      )
    end
  end

  test "current marks old status as stale when lora is enabled" do
    Dir.mktmpdir("vg-lora-status") do |dir|
      path = Pathname.new(File.join(dir, "lora_receiver_status.json"))
      File.write(path, JSON.generate({status: "connected", updated_at: "2026-08-25T12:00:00Z"}))

      status = LoraReceiverStatus.current(
        path: path,
        environ: {
          "LORA_ENABLED" => "true",
          "LORA_STATUS_STALE_AFTER_SECONDS" => "120"
        },
        now: Time.iso8601("2026-08-25T12:03:00Z")
      )

      assert_equal "stale", status["status"]
      assert_equal "connected", status["last_known_status"]
      assert_equal "LoRa receiver status is stale", status["last_error"]
    end
  end
end
