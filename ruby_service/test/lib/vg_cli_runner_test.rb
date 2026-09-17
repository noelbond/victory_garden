require "test_helper"

class VgCliRunnerTest < ActiveSupport::TestCase
  test "zones show omits the legacy zone irrigation line" do
    zone = create(:zone)

    output, = capture_io { VgCli::Runner.run(["zones", "show", zone.zone_id]) }

    assert_includes output, "zone_id:"
    assert_includes output, "nodes:"
  end
end
