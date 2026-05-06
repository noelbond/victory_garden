require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  # --- issue_guidance_for ---

  test "returns correct guidance for a known zone_notification key" do
    result = issue_guidance_for(kind: :zone_notification, key: "Stale reading")

    assert_equal "The latest reading is too old to trust for current watering decisions.", result[:description]
    assert_includes result[:fix], "publishing on schedule"
  end

  test "returns DEFAULT_GUIDANCE for an unknown zone_notification key" do
    result = issue_guidance_for(kind: :zone_notification, key: "Nonexistent Key")

    assert_equal DEFAULT_GUIDANCE[:description], result[:description]
    assert_equal DEFAULT_GUIDANCE[:fix], result[:fix]
  end

  test "uses detail as description when key is unknown and detail is present" do
    result = issue_guidance_for(kind: :zone_notification, key: "Unknown", detail: "Custom detail here")

    assert_equal "Custom detail here", result[:description]
    assert_equal DEFAULT_GUIDANCE[:fix], result[:fix]
  end

  test "returns correct guidance for a known health_notification key" do
    result = issue_guidance_for(kind: :health_notification, key: "Stale Nodes")

    assert_includes result[:description], "nodes have not checked in recently"
  end

  test "returns correct guidance for a known fault_code key" do
    result = issue_guidance_for(kind: :fault_code, key: "ACTUATOR_TIMEOUT")

    assert_includes result[:description], "did not receive a terminal actuator status"
  end

  test "returns correct guidance for a known runtime_error key" do
    result = issue_guidance_for(kind: :runtime_error, key: "stale sample")

    assert_includes result[:description], "too old to trust"
  end

  test "returns DEFAULT_GUIDANCE for an unknown kind" do
    result = issue_guidance_for(kind: :totally_unknown, key: "anything")

    assert_equal DEFAULT_GUIDANCE[:description], result[:description]
    assert_equal DEFAULT_GUIDANCE[:fix], result[:fix]
  end

  # --- node_config_guidance ---

  test "localhost:1883 config error returns special broker guidance" do
    node = stub_node(
      config_status: "error",
      config_error: 'Connection refused - connect(2) for "localhost" port 1883'
    )

    result = node_config_guidance(node)

    assert_includes result[:description], "localhost:1883"
    assert_includes result[:fix], "Open Settings"
  end

  test "config_status error without localhost returns generic error guidance" do
    node = stub_node(config_status: "error", config_error: "some other error")

    result = node_config_guidance(node)

    assert_equal "some other error", result[:description]
    assert_includes result[:fix], "republish config"
  end

  test "config_status error with blank error uses fallback description" do
    node = stub_node(config_status: "error", config_error: "")

    result = node_config_guidance(node)

    assert_includes result[:description], "last config publish or acknowledgement failed"
  end

  test "config_status pending returns pending guidance" do
    node = stub_node(config_status: "pending", config_error: "")

    result = node_config_guidance(node)

    assert_includes result[:description], "not acknowledged"
    assert_includes result[:fix], "Republish Config"
  end

  test "config_status applied returns no-action guidance" do
    node = stub_node(config_status: "applied", config_error: "")

    result = node_config_guidance(node)

    assert_includes result[:description], "acknowledged and applied"
    assert_equal "No action needed.", result[:fix]
  end

  test "nil config_status returns no-config-recorded guidance" do
    node = stub_node(config_status: nil, config_error: nil)

    result = node_config_guidance(node)

    assert_includes result[:description], "No config status has been recorded"
    assert_includes result[:fix], "Republish config"
  end

  # --- fault_guidance ---

  test "fault_guidance returns correct guidance for STALE_SENSOR" do
    fault = Struct.new(:fault_code, :detail).new("STALE_SENSOR", nil)

    result = fault_guidance(fault)

    assert_includes result[:description], "too old to use safely"
  end

  test "fault_guidance returns correct guidance for NO_FLOW" do
    fault = Struct.new(:fault_code, :detail).new("NO_FLOW", nil)

    result = fault_guidance(fault)

    assert_includes result[:description], "no water flow was detected"
  end

  test "fault_guidance returns DEFAULT_GUIDANCE for unknown fault code" do
    fault = Struct.new(:fault_code, :detail).new("UNKNOWN_CODE", "raw detail")

    result = fault_guidance(fault)

    assert_equal "raw detail", result[:description]
    assert_equal DEFAULT_GUIDANCE[:fix], result[:fix]
  end

  # --- reading_error_guidance ---

  test "reading_error_guidance returns no-error result for nil reading" do
    result = reading_error_guidance(nil)

    assert_equal "The reading does not report an error.", result[:description]
    assert_equal "No action needed.", result[:fix]
  end

  test "reading_error_guidance returns no-error result when last_error is none" do
    reading = Struct.new(:last_error).new("none")

    result = reading_error_guidance(reading)

    assert_equal "The reading does not report an error.", result[:description]
  end

  test "reading_error_guidance returns known guidance for stale sample" do
    reading = Struct.new(:last_error).new("stale sample")

    result = reading_error_guidance(reading)

    assert_includes result[:description], "too old to trust"
    assert_includes result[:fix], "publishing on schedule"
  end

  test "reading_error_guidance uses fallback fix for unknown error" do
    reading = Struct.new(:last_error).new("unknown error type")

    result = reading_error_guidance(reading)

    assert_includes result[:fix], "Check the node that produced this reading"
  end

  # --- node_runtime_error_guidance ---

  test "node_runtime_error_guidance returns no-error result when last_error is blank" do
    node = stub_node(last_error: "")

    result = node_runtime_error_guidance(node)

    assert_equal "The node has not reported a runtime error.", result[:description]
    assert_equal "No action needed.", result[:fix]
  end

  test "node_runtime_error_guidance returns no-error result when last_error is none" do
    node = stub_node(last_error: "none")

    result = node_runtime_error_guidance(node)

    assert_equal "The node has not reported a runtime error.", result[:description]
  end

  test "node_runtime_error_guidance returns known guidance for sensor drift" do
    node = stub_node(last_error: "sensor drift")

    result = node_runtime_error_guidance(node)

    assert_includes result[:description], "unstable or suspicious sensor behavior"
  end

  test "node_runtime_error_guidance uses fallback fix for unknown error" do
    node = stub_node(last_error: "unexpected fault")

    result = node_runtime_error_guidance(node)

    assert_includes result[:fix], "request a fresh reading or reboot the node"
  end

  # --- actuator_fault_guidance ---

  test "actuator_fault_guidance returns no-fault result for nil status" do
    result = actuator_fault_guidance(nil)

    assert_equal "The actuator status does not report a fault code.", result[:description]
    assert_equal "No action needed.", result[:fix]
  end

  test "actuator_fault_guidance returns no-fault result for blank fault_code" do
    status = Struct.new(:fault_code, :fault_detail).new("", nil)

    result = actuator_fault_guidance(status)

    assert_equal "The actuator status does not report a fault code.", result[:description]
  end

  test "actuator_fault_guidance returns correct guidance for ACTUATOR_TIMEOUT" do
    status = Struct.new(:fault_code, :fault_detail).new("ACTUATOR_TIMEOUT", nil)

    result = actuator_fault_guidance(status)

    assert_includes result[:description], "did not receive a terminal actuator status"
  end

  private

  def stub_node(config_status: nil, config_error: nil, last_error: nil)
    Struct.new(:config_status, :config_error, :last_error).new(
      config_status.to_s,
      config_error.to_s,
      last_error.to_s
    )
  end
end
