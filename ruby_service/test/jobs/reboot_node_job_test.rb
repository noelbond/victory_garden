require "test_helper"

class RebootNodeJobTest < ActiveSupport::TestCase
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

  test "publishes the reboot command and marks the node command sent" do
    zone = create(:zone, zone_id: "zone1")
    command = NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-cmd-001",
      status: "queued",
      issued_at: Time.current
    )

    published = []

    stub_singleton_method(MqttClient, :reboot_node, ->(**kwargs) { published << kwargs }) do
      RebootNodeJob.perform_now(zone_id: "zone1", command_id: "combined-zone1-ch0-cmd-001", node_id: "combined-zone1-ch0")
    end

    assert_equal [{ zone_id: "zone1", command_id: "combined-zone1-ch0-cmd-001", node_id: "combined-zone1-ch0" }], published
    assert_equal "command_sent", command.reload.status
  end

  test "does not schedule its own timeout watchdog -- that's scheduled independently by the controller" do
    zone = create(:zone, zone_id: "zone1")
    NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-cmd-002",
      status: "queued",
      issued_at: Time.current
    )

    stub_singleton_method(MqttClient, :reboot_node, ->(**_kwargs) {}) do
      assert_no_enqueued_jobs only: NodeCommandTimeoutJob do
        RebootNodeJob.perform_now(zone_id: "zone1", command_id: "combined-zone1-ch0-cmd-002", node_id: "combined-zone1-ch0")
      end
    end
  end

  test "does not mark the command sent if the publish fails -- left available for the independent timeout watchdog to catch" do
    zone = create(:zone, zone_id: "zone1")
    command = NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-cmd-003",
      status: "queued",
      issued_at: Time.current
    )

    # MQTT::Exception (not a StandardError subclass) is now caught by
    # retry_on explicitly -- perform_now doesn't raise, it retries.
    stub_singleton_method(MqttClient, :reboot_node, ->(**_kwargs) { raise MQTT::NotConnectedException }) do
      assert_enqueued_with(job: RebootNodeJob) do
        assert_nothing_raised do
          RebootNodeJob.perform_now(zone_id: "zone1", command_id: "combined-zone1-ch0-cmd-003", node_id: "combined-zone1-ch0")
        end
      end
    end

    assert_equal "queued", command.reload.status
  end
end
