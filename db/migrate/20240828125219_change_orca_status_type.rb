class ChangeOrcaStatusType < ActiveRecord::Migration[7.0]
  def up
    add_column :graders, :orca_jsonb_status, :jsonb, default: false, null: false
    Grader.reset_column_information
    Grader.where(orca_status: true).update_all(orca_jsonb_status: {
                                                 current_build: {
                                                   completed: true,
                                                   succesful: true,
                                                   build_time: DateTime.now
                                                 },
                                                 last_build: nil
                                               })
    remove_column :graders, :orca_status
    rename_column :graders, :orca_jsonb_status, :orca_status
  end

  def down
    rename_column :graders, :orca_status, :orca_jsonb_status
    add_column :graders, :orca_status, :boolean, default: false, null: false
    Grader.reset_column_information
    Grader.where.not(orca_jsonb_status: false).update_all(orca_status: true)
    remove_column :graders, :orca_jsonb_status
  end
end
