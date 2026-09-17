class EnforcePositiveNodeIrrigationLines < ActiveRecord::Migration[8.0]
  CHECK_NAME = "chk_nodes_irrigation_line_positive"

  def up
    add_check_constraint :nodes, "irrigation_line IS NULL OR irrigation_line > 0", name: CHECK_NAME
  end

  def down
    remove_check_constraint :nodes, name: CHECK_NAME
  end
end
