class RemoveConfirmableFromUsers < ActiveRecord::Migration[7.2]
  def change
    # Remove confirmable columns
    remove_column :users, :confirmation_token, :string
    remove_column :users, :confirmed_at, :datetime
    remove_column :users, :confirmation_sent_at, :datetime
    remove_column :users, :unconfirmed_email, :string
  end
end
