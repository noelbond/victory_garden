require "test_helper"

class NodeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def valid_attrs
    {
      node_id: "pico-w-test-001",
      last_seen_at: Time.current
    }
  end

  test "valid with required fields only" do
    assert Node.new(valid_attrs).valid?
  end

  test "requires node_id" do
    node = Node.new(valid_attrs.merge(node_id: nil))
    assert_not node.valid?
    assert_includes node.errors[:node_id], "can't be blank"
  end

  test "requires last_seen_at" do
    node = Node.new(valid_attrs.merge(last_seen_at: nil))
    assert_not node.valid?
    assert_includes node.errors[:last_seen_at], "can't be blank"
  end

  test "rejects duplicate node_id" do
    Node.create!(valid_attrs)
    node = Node.new(valid_attrs)
    assert_not node.valid?
    assert_includes node.errors[:node_id], "has already been taken"
  end

  test "rejects battery_voltage above 10" do
    node = Node.new(valid_attrs.merge(battery_voltage: 10.1))
    assert_not node.valid?
    assert_includes node.errors[:battery_voltage], "must be less than or equal to 10"
  end

  test "rejects negative battery_voltage" do
    node = Node.new(valid_attrs.merge(battery_voltage: -0.1))
    assert_not node.valid?
    assert_includes node.errors[:battery_voltage], "must be greater than or equal to 0"
  end

  test "accepts battery_voltage at boundary values" do
    assert Node.new(valid_attrs.merge(battery_voltage: 0)).valid?
    assert Node.new(valid_attrs.merge(battery_voltage: 10)).valid?
  end

  test "rejects positive wifi_rssi" do
    node = Node.new(valid_attrs.merge(wifi_rssi: 1))
    assert_not node.valid?
    assert_includes node.errors[:wifi_rssi], "must be less than or equal to 0"
  end

  test "rejects wifi_rssi below -130" do
    node = Node.new(valid_attrs.merge(wifi_rssi: -131))
    assert_not node.valid?
    assert_includes node.errors[:wifi_rssi], "must be greater than or equal to -130"
  end

  test "accepts wifi_rssi at boundary values" do
    assert Node.new(valid_attrs.merge(wifi_rssi: 0)).valid?
    assert Node.new(valid_attrs.merge(wifi_rssi: -130)).valid?
  end

  test "rejects invalid config_status" do
    node = Node.new(valid_attrs.merge(config_status: "ready"))
    assert_not node.valid?
    assert_includes node.errors[:config_status], "is not included in the list"
  end

  test "accepts all valid config_status values" do
    %w[pending applied error unassigned].each do |status|
      assert Node.new(valid_attrs.merge(config_status: status)).valid?,
             "expected config_status #{status.inspect} to be valid"
    end
  end

  test "accepts nil config_status" do
    assert Node.new(valid_attrs.merge(config_status: nil)).valid?
  end

  test "accepts moisture calibration when both raw values are present" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: 943))

    assert node.valid?
    assert node.calibration_configured?
  end

  test "rejects partial moisture calibration" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: nil))

    assert_not node.valid?
    assert_includes node.errors[:base], "moisture calibration requires both dry and wet raw values"
  end

  test "rejects equal dry and wet moisture calibration values" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: 552))

    assert_not node.valid?
    assert_includes node.errors[:base], "moisture calibration dry and wet raw values cannot be the same"
  end

  test "unclaimed scope returns nodes without a zone" do
    zone = create(:zone)
    claimed = Node.create!(valid_attrs.merge(node_id: "claimed-node", zone: zone))
    unclaimed = Node.create!(valid_attrs.merge(node_id: "unclaimed-node"))

    assert_includes Node.unclaimed, unclaimed
    assert_not_includes Node.unclaimed, claimed
  end

  test "claimed scope returns nodes with a zone" do
    zone = create(:zone)
    claimed = Node.create!(valid_attrs.merge(node_id: "claimed-node", zone: zone))
    unclaimed = Node.create!(valid_attrs.merge(node_id: "unclaimed-node"))

    assert_includes Node.claimed, claimed
    assert_not_includes Node.claimed, unclaimed
  end

  test "claimed? returns true when zone is assigned" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))
    assert node.claimed?
  end

  test "claimed? returns false when no zone is assigned" do
    node = Node.create!(valid_attrs)
    assert_not node.claimed?
  end

  test "enqueues config publish when zone assignment changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs)

    assert_enqueued_with(job: ConfigPublishJob) do
      node.update!(zone: zone)
    end
  end

  test "enqueues node config publish when claimed node calibration changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      node.update!(moisture_raw_dry: 552, moisture_raw_wet: 943)
    end
  end

  test "does not enqueue node config publish when unclaimed node calibration changes" do
    node = Node.create!(valid_attrs)

    assert_no_enqueued_jobs only: PublishNodeConfigJob do
      node.update!(moisture_raw_dry: 552, moisture_raw_wet: 943)
    end
  end

  test "enqueues config publish when a claimed node is destroyed" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_enqueued_with(job: ConfigPublishJob) do
      node.destroy!
    end
  end

  test "does not enqueue config publish when an unclaimed node is destroyed" do
    node = Node.create!(valid_attrs)

    assert_no_enqueued_jobs only: ConfigPublishJob do
      node.destroy!
    end
  end
end
