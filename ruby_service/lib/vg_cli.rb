require_relative "vg_cli/table"
require_relative "vg_cli/runner"

module VgCli
  def self.run(argv)
    Runner.run(argv)
  end
end
